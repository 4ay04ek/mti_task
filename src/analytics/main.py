import asyncio
import logging
import os
from contextlib import asynccontextmanager, suppress
from datetime import date, datetime, time, timedelta, timezone
from typing import Literal

from aiokafka import AIOKafkaConsumer, TopicPartition
from fastapi import Depends, FastAPI, HTTPException
from opentelemetry import propagate, trace
from pydantic import AwareDatetime, BaseModel, Field, model_validator
from sqlalchemy import DateTime, Integer, String, create_engine, func, select, text
from sqlalchemy.orm import DeclarativeBase, Mapped, Session, mapped_column

from src.common.auth import require_admin
from src.common.observability import configure


engine = create_engine(os.environ["DATABASE_URL"], pool_pre_ping=True)
logger = logging.getLogger("analytics")
tracer = trace.get_tracer("analytics")


class Base(DeclarativeBase):
    pass


class TicketProjection(Base):
    __tablename__ = "ticket_projection"
    id: Mapped[int] = mapped_column(primary_key=True)
    version: Mapped[int] = mapped_column(Integer)
    status: Mapped[str] = mapped_column(String(20))
    category: Mapped[str] = mapped_column(String(20))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), index=True)
    due_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    received_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))


class ProcessedEvent(Base):
    __tablename__ = "processed_event"
    id: Mapped[str] = mapped_column(String(100), primary_key=True)


class Snapshot(BaseModel):
    id: int = Field(gt=0)
    version: int = Field(gt=0)
    status: Literal["new", "in_progress", "completed"]
    category: Literal["it", "equipment", "household"]
    created_at: AwareDatetime
    due_at: AwareDatetime | None = None
    completed_at: AwareDatetime | None = None


class TicketEvent(BaseModel):
    event_id: str = Field(min_length=1, max_length=100)
    ticket_id: int = Field(gt=0)
    version: int = Field(gt=0)
    occurred_at: AwareDatetime
    ticket: Snapshot
    trace_context: dict[str, str] = Field(default_factory=dict)

    @model_validator(mode="after")
    def consistent_snapshot(self):
        if self.ticket_id != self.ticket.id or self.version != self.ticket.version:
            raise ValueError("Event and snapshot do not match")
        if self.ticket.status == "completed" and self.ticket.completed_at is None:
            raise ValueError("Completed ticket must have a completion time")
        return self


def apply_event(event: TicketEvent):
    with Session(engine) as session, session.begin():
        if session.get(ProcessedEvent, event.event_id):
            return
        item = session.get(TicketProjection, event.ticket_id, with_for_update=True)
        if item is None or item.version < event.version:
            if item is None:
                item = TicketProjection(id=event.ticket_id)
                session.add(item)
            for key in ("version", "status", "category", "created_at", "due_at", "completed_at"):
                setattr(item, key, getattr(event.ticket, key))
            item.received_at = datetime.now(timezone.utc)
        session.add(ProcessedEvent(id=event.event_id))


async def consume_events():
    while True:
        consumer = AIOKafkaConsumer(
            "ticket.events",
            bootstrap_servers=os.getenv("KAFKA_BOOTSTRAP_SERVERS", "kafka:9092"),
            group_id="analytics",
            enable_auto_commit=False,
            auto_offset_reset="earliest",
        )
        try:
            await consumer.start()
            async for record in consumer:
                event = TicketEvent.model_validate_json(record.value)
                context = {
                    key: value.decode("utf-8") for key, value in record.headers
                    if key in ("traceparent", "tracestate") and value is not None
                } or event.trace_context
                with tracer.start_as_current_span(
                    "ticket.events process", context=propagate.extract(context),
                    kind=trace.SpanKind.CONSUMER,
                ):
                    await asyncio.to_thread(apply_event, event)
                    await consumer.commit({
                        TopicPartition(record.topic, record.partition): record.offset + 1
                    })
                    logger.info("Ticket projection updated")
        except asyncio.CancelledError:
            raise
        except Exception:
            # Do not log payloads or validation errors containing ticket text.
            logger.error("Event consumption failed; uncommitted event will be retried")
        finally:
            with suppress(Exception):
                await consumer.stop()
        await asyncio.sleep(5)


@asynccontextmanager
async def lifespan(app: FastAPI):
    def create_tables():
        with engine.begin() as connection:
            if engine.dialect.name == "postgresql":
                connection.execute(text("SELECT pg_advisory_xact_lock(9812402)"))
            Base.metadata.create_all(connection)

    await asyncio.to_thread(create_tables)
    consumer = asyncio.create_task(consume_events())
    try:
        yield
    finally:
        consumer.cancel()
        with suppress(asyncio.CancelledError):
            await consumer
        engine.dispose()


app = FastAPI(title="Заявка: аналитика", lifespan=lifespan)
configure(app, "analytics", engine)


@app.get("/health")
def health():
    with engine.connect() as connection:
        connection.execute(select(1))
    return {"status": "ok"}


def utc(value: datetime):
    return value.replace(tzinfo=timezone.utc) if value.tzinfo is None else value


@app.get("/", dependencies=[Depends(require_admin)])
def dashboard(date_from: date | None = None, date_to: date | None = None):
    if date_from and date_to and date_from > date_to:
        raise HTTPException(422, "Начало периода должно быть не позже окончания")
    if date_to == date.max:
        raise HTTPException(422, "Дата окончания слишком велика")
    filters = []
    if date_from:
        filters.append(TicketProjection.created_at >= datetime.combine(date_from, time.min, timezone.utc))
    if date_to:
        filters.append(TicketProjection.created_at < datetime.combine(date_to + timedelta(days=1), time.min, timezone.utc))
    with Session(engine) as session:
        statuses = {"new": 0, "in_progress": 0, "completed": 0}
        categories = {"it": 0, "equipment": 0, "household": 0}
        statuses.update(dict(session.execute(
            select(TicketProjection.status, func.count()).where(*filters).group_by(TicketProjection.status)
        ).all()))
        categories.update(dict(session.execute(
            select(TicketProjection.category, func.count()).where(*filters).group_by(TicketProjection.category)
        ).all()))
        overdue = session.scalar(select(func.count()).select_from(TicketProjection).where(
            *filters, TicketProjection.status != "completed",
            TicketProjection.due_at < datetime.now(timezone.utc),
        ))
        completed = session.execute(select(
            TicketProjection.created_at, TicketProjection.completed_at,
        ).where(*filters, TicketProjection.status == "completed")).all()
        hours = [(utc(end) - utc(start)).total_seconds() / 3600 for start, end in completed if end]
        updated_at = session.scalar(select(func.max(TicketProjection.received_at)))
        return {
            "total": sum(statuses.values()), "statuses": statuses, "categories": categories,
            "overdue": overdue,
            "average_completion_hours": sum(hours) / len(hours) if hours else None,
            "updated_at": utc(updated_at).isoformat() if updated_at else None,
        }
