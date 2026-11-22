import asyncio
import csv
import io
import json
import logging
import os
from contextlib import asynccontextmanager, suppress
from datetime import datetime, timezone
from typing import Literal
from uuid import uuid4

import httpx
from aiokafka import AIOKafkaProducer
from fastapi import Depends, FastAPI, HTTPException, Query
from fastapi.responses import Response
from opentelemetry import propagate, trace
from pydantic import AwareDatetime, BaseModel, ConfigDict, Field, field_validator
from sqlalchemy import Boolean, DateTime, Integer, JSON, String, Text, create_engine, or_, select, text
from sqlalchemy.orm import DeclarativeBase, Mapped, Session, mapped_column

from src.common.auth import Principal, get_principal, require_admin, require_trainer
from src.common.observability import configure


Category = Literal['it', 'equipment', 'household']
Status = Literal['new', 'in_progress', 'completed']
log = logging.getLogger('tickets')
tracer = trace.get_tracer('tickets')
database_url = os.environ.get('DATABASE_URL', 'postgresql+psycopg://tickets:tickets@postgres/tickets')
engine = create_engine(database_url, pool_pre_ping=True, hide_parameters=True,
                       **({'connect_args': {'check_same_thread': False}} if database_url.startswith('sqlite') else {}))


class Base(DeclarativeBase):
    pass


class Ticket(Base):
    __tablename__ = 'tickets'
    id: Mapped[int] = mapped_column(primary_key=True)
    title: Mapped[str] = mapped_column(String(200))
    description: Mapped[str] = mapped_column(Text)
    category: Mapped[str] = mapped_column(String(20), index=True)
    category_checked: Mapped[bool] = mapped_column(Boolean, default=False)
    status: Mapped[str] = mapped_column(String(20), default='new', index=True)
    author_id: Mapped[str] = mapped_column(String(100), index=True)
    assignee_id: Mapped[str | None] = mapped_column(String(100), nullable=True, index=True)
    due_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), index=True)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    result: Mapped[str | None] = mapped_column(Text, nullable=True)
    version: Mapped[int] = mapped_column(Integer, default=1)


class History(Base):
    __tablename__ = 'ticket_history'
    id: Mapped[int] = mapped_column(primary_key=True)
    ticket_id: Mapped[int] = mapped_column(Integer, index=True)
    actor_id: Mapped[str] = mapped_column(String(100))
    actor_name: Mapped[str] = mapped_column(String(200))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    changes: Mapped[dict] = mapped_column(JSON)


class Outbox(Base):
    __tablename__ = 'outbox'
    id: Mapped[int] = mapped_column(primary_key=True)
    payload: Mapped[dict] = mapped_column(JSON)


class CreateTicket(BaseModel):
    model_config = ConfigDict(extra='forbid', str_strip_whitespace=True)
    title: str = Field(min_length=1, max_length=200)
    description: str = Field(min_length=1, max_length=10000)
    category: Category


class UpdateTicket(BaseModel):
    model_config = ConfigDict(extra='forbid', str_strip_whitespace=True)
    category: Category | None = None
    assignee_id: str | None = Field(default=None, min_length=1, max_length=100, pattern=r'^[A-Za-z0-9_-]+$')
    due_at: AwareDatetime | None = None
    status: Status | None = None
    result: str | None = Field(default=None, max_length=10000)

    @field_validator('category', 'status')
    @classmethod
    def not_null(cls, value):
        if value is None:
            raise ValueError('Поле не может быть null')
        return value


def utcnow():
    return datetime.now(timezone.utc)


def date_text(value):
    if value is None:
        return None
    if value.tzinfo is None:
        value = value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc).isoformat()


def serialize(ticket):
    return {name: date_text(value) if name.endswith('_at') else value for name, value in {
        'id': ticket.id, 'title': ticket.title, 'description': ticket.description,
        'category': ticket.category, 'status': ticket.status, 'author_id': ticket.author_id,
        'assignee_id': ticket.assignee_id, 'due_at': ticket.due_at, 'created_at': ticket.created_at,
        'updated_at': ticket.updated_at, 'completed_at': ticket.completed_at,
        'result': ticket.result, 'version': ticket.version,
    }.items()}


def record(session, ticket, principal, changes):
    session.flush()
    session.add(History(ticket_id=ticket.id, actor_id=principal.subject,
                        actor_name=principal.name[:200], created_at=ticket.updated_at, changes=changes))
    carrier = {}
    propagate.inject(carrier)
    session.add(Outbox(payload={
        'event_id': str(uuid4()), 'ticket_id': ticket.id, 'version': ticket.version,
        'occurred_at': date_text(ticket.updated_at), 'ticket': serialize(ticket), 'trace_context': carrier,
    }))


async def publish_outbox():
    while True:
        producer = AIOKafkaProducer(
            bootstrap_servers=os.environ.get('KAFKA_BOOTSTRAP_SERVERS', 'kafka:9092'),
            enable_idempotence=True, acks='all', request_timeout_ms=10000,
        )
        try:
            await producer.start()
            while True:
                sent = False
                with Session(engine) as session, session.begin():
                    event = session.scalar(select(Outbox).order_by(Outbox.id).limit(1)
                                           .with_for_update(skip_locked=True))
                    if event:
                        payload = event.payload
                        context = propagate.extract(payload.get('trace_context', {}))
                        with tracer.start_as_current_span('ticket.events publish', context=context,
                                                          kind=trace.SpanKind.PRODUCER):
                            headers = {}
                            propagate.inject(headers)
                            await producer.send_and_wait(
                                'ticket.events', json.dumps(payload).encode(),
                                key=str(payload['ticket_id']).encode(),
                                headers=[(key, value.encode()) for key, value in headers.items()],
                            )
                        session.delete(event)
                        sent = True
                if sent:
                    log.info('Ticket event published')
                else:
                    await asyncio.sleep(0.5)
        except asyncio.CancelledError:
            raise
        except Exception as error:
            log.warning('Outbox delivery interrupted: %s', type(error).__name__)
            await asyncio.sleep(3)
        finally:
            with suppress(Exception):
                await producer.stop()


@asynccontextmanager
async def lifespan(app):
    with engine.begin() as connection:
        if engine.dialect.name == 'postgresql':
            connection.execute(text('SELECT pg_advisory_xact_lock(81001)'))
        Base.metadata.create_all(connection)
    task = asyncio.create_task(publish_outbox())
    try:
        yield
    finally:
        task.cancel()
        with suppress(asyncio.CancelledError):
            await task
        engine.dispose()


app = FastAPI(title='Заявки', lifespan=lifespan)
configure(app, 'tickets', engine)


def db_session():
    with Session(engine) as session:
        yield session


def keycloak_client():
    base = os.environ.get('KEYCLOAK_URL', 'http://keycloak:8080').rstrip('/')
    realm = os.environ.get('KEYCLOAK_REALM', 'zayavka')
    secret = os.environ.get('KEYCLOAK_CLIENT_SECRET')
    if not secret:
        raise HTTPException(503, 'Не настроен доступ к каталогу пользователей')
    client = httpx.Client(base_url=base, timeout=10)
    try:
        response = client.post(f'/realms/{realm}/protocol/openid-connect/token', data={
            'grant_type': 'client_credentials',
            'client_id': os.environ.get('KEYCLOAK_CLIENT_ID', 'tickets-service'),
            'client_secret': secret,
        })
        response.raise_for_status()
        client.headers['Authorization'] = f"Bearer {response.json()['access_token']}"
        return client, f'/admin/realms/{realm}'
    except (httpx.HTTPError, KeyError, ValueError):
        client.close()
        raise HTTPException(503, 'Каталог пользователей недоступен') from None


def validate_assignee(assignee_id):
    client, prefix = keycloak_client()
    try:
        user = client.get(f'{prefix}/users/{assignee_id}')
        if user.status_code == 404:
            raise HTTPException(422, 'Исполнитель не найден')
        user.raise_for_status()
        roles = client.get(f'{prefix}/users/{assignee_id}/role-mappings/realm/composite')
        roles.raise_for_status()
        if not user.json().get('enabled') or not any(role['name'] == 'executor' for role in roles.json()):
            raise HTTPException(422, 'Пользователь должен быть действующим исполнителем')
    except (httpx.HTTPError, KeyError, ValueError):
        raise HTTPException(503, 'Каталог пользователей недоступен') from None
    finally:
        client.close()


def visible_query(principal):
    statement = select(Ticket)
    if 'admin' not in principal.roles:
        statement = statement.where(or_(Ticket.author_id == principal.subject,
                                         Ticket.assignee_id == principal.subject))
    return statement


def filtered_query(principal, q, status, category, assignee_id):
    statement = visible_query(principal)
    if q:
        pattern = '%' + q.replace('\\', '\\\\').replace('%', '\\%').replace('_', '\\_') + '%'
        statement = statement.where(or_(Ticket.title.ilike(pattern, escape='\\'),
                                         Ticket.description.ilike(pattern, escape='\\')))
    for column, value in ((Ticket.status, status), (Ticket.category, category),
                          (Ticket.assignee_id, assignee_id)):
        if value:
            statement = statement.where(column == value)
    return statement.order_by(Ticket.id.desc())


def accessible_ticket(session, ticket_id, principal, lock=False):
    statement = visible_query(principal).where(Ticket.id == ticket_id)
    if lock:
        statement = statement.with_for_update()
    ticket = session.scalar(statement)
    if ticket is None:
        raise HTTPException(404, 'Заявка не найдена')
    return ticket


@app.get('/health')
def health():
    return {'status': 'ok'}


@app.get('/me')
def me(principal: Principal = Depends(get_principal)):
    return {'id': principal.subject, 'name': principal.name, 'roles': sorted(principal.roles)}


@app.get('/users')
def users(principal: Principal = Depends(require_admin)):
    client, prefix = keycloak_client()
    result = []
    try:
        offset = 0
        while True:
            response = client.get(f'{prefix}/roles/executor/users', params={'first': offset, 'max': 100})
            response.raise_for_status()
            page = response.json()
            for user in page:
                if user.get('enabled'):
                    name = ' '.join(filter(None, [user.get('firstName'), user.get('lastName')]))
                    result.append({'id': user['id'], 'name': name or user['username']})
            if len(page) < 100:
                return sorted(result, key=lambda user: user['name'])
            offset += 100
    except (httpx.HTTPError, KeyError, ValueError):
        raise HTTPException(503, 'Каталог пользователей недоступен') from None
    finally:
        client.close()


@app.get('/tickets')
def list_tickets(q: str = Query(default='', max_length=200), status: Status | None = None,
                 category: Category | None = None, assignee_id: str | None = None,
                 principal: Principal = Depends(get_principal), session: Session = Depends(db_session)):
    return [serialize(ticket) for ticket in session.scalars(
        filtered_query(principal, q, status, category, assignee_id))]


@app.post('/tickets', status_code=201)
def create_ticket(payload: CreateTicket, principal: Principal = Depends(get_principal),
                  session: Session = Depends(db_session)):
    if not principal.roles.intersection({'employee', 'executor', 'admin'}):
        raise HTTPException(403, 'Требуется роль пользователя приложения')
    now = utcnow()
    ticket = Ticket(**payload.model_dump(), author_id=principal.subject, status='new',
                    created_at=now, updated_at=now, version=1, category_checked='admin' in principal.roles)
    with session.begin():
        session.add(ticket)
        record(session, ticket, principal, {'status': {'from': None, 'to': 'new'}})
        result = serialize(ticket)
    log.info('Ticket created')
    return result


def csv_cell(value):
    value = '' if value is None else str(value)
    return "'" + value if value.lstrip().startswith(('=', '+', '-', '@')) else value


@app.get('/tickets/export')
def export_tickets(q: str = Query(default='', max_length=200), status: Status | None = None,
                   category: Category | None = None, assignee_id: str | None = None,
                   principal: Principal = Depends(get_principal), session: Session = Depends(db_session)):
    output = io.StringIO()
    writer = csv.writer(output)
    columns = ['id', 'title', 'description', 'category', 'status', 'author_id', 'assignee_id',
               'due_at', 'created_at', 'updated_at', 'completed_at', 'result', 'version']
    writer.writerow(columns)
    for ticket in session.scalars(filtered_query(principal, q, status, category, assignee_id)):
        data = serialize(ticket)
        writer.writerow([csv_cell(data[name]) for name in columns])
    return Response('\ufeff' + output.getvalue(), media_type='text/csv; charset=utf-8',
                    headers={'Content-Disposition': 'attachment; filename="tickets.csv"'})


@app.get('/tickets/{ticket_id}')
def get_ticket(ticket_id: int, principal: Principal = Depends(get_principal),
               session: Session = Depends(db_session)):
    return serialize(accessible_ticket(session, ticket_id, principal))


@app.patch('/tickets/{ticket_id}')
def update_ticket(ticket_id: int, payload: UpdateTicket, principal: Principal = Depends(get_principal),
                  session: Session = Depends(db_session)):
    updates = payload.model_dump(exclude_unset=True)
    if not updates:
        raise HTTPException(422, 'Не указаны изменения')
    admin = 'admin' in principal.roles
    if not admin and updates.keys() - {'status', 'result'}:
        raise HTTPException(403, 'Только администратор может изменять назначение и категорию')
    if updates.get('assignee_id'):
        validate_assignee(updates['assignee_id'])
    with session.begin():
        ticket = accessible_ticket(session, ticket_id, principal, lock=True)
        if not admin and ('executor' not in principal.roles or ticket.assignee_id != principal.subject):
            raise HTTPException(403, 'Изменять статус может только назначенный исполнитель')
        if ticket.status == 'completed' and updates.keys() - {'category'}:
            raise HTTPException(409, 'Выполненную заявку можно только переклассифицировать')
        next_status = updates.get('status', ticket.status)
        assignee = updates.get('assignee_id', ticket.assignee_id)
        if next_status != 'new' and not assignee:
            raise HTTPException(422, 'Для работы с заявкой требуется исполнитель')
        if next_status != ticket.status:
            if (ticket.status, next_status) not in {('new', 'in_progress'), ('in_progress', 'completed')}:
                raise HTTPException(409, 'Недопустимый переход статуса')
        result = updates.get('result', ticket.result)
        if next_status == 'completed' and (not result or not result.strip()):
            raise HTTPException(422, 'Укажите результат выполнения')
        if 'result' in updates and next_status != 'completed':
            raise HTTPException(422, 'Результат указывается при завершении заявки')
        changes = {}
        for key, value in updates.items():
            old = getattr(ticket, key)
            old_value = date_text(old) if key.endswith('_at') else old
            new_value = date_text(value) if key.endswith('_at') else value
            if old_value != new_value:
                setattr(ticket, key, value)
                changes[key] = {'from': old_value, 'to': new_value}
        if admin and 'category' in updates and not ticket.category_checked:
            ticket.category_checked = True
            changes['category_checked'] = {'from': False, 'to': True}
        if not changes:
            return serialize(ticket)
        now = utcnow()
        if next_status == 'completed' and ticket.completed_at is None:
            ticket.completed_at = now
        ticket.updated_at = now
        ticket.version += 1
        record(session, ticket, principal, changes)
        data = serialize(ticket)
    log.info('Ticket updated')
    return data


@app.get('/tickets/{ticket_id}/history')
def history(ticket_id: int, principal: Principal = Depends(get_principal),
            session: Session = Depends(db_session)):
    accessible_ticket(session, ticket_id, principal)
    return [{'id': entry.id, 'ticket_id': entry.ticket_id, 'actor_id': entry.actor_id,
             'actor_name': entry.actor_name, 'created_at': date_text(entry.created_at),
             'changes': entry.changes} for entry in session.scalars(
                 select(History).where(History.ticket_id == ticket_id).order_by(History.id))]


@app.get('/internal/training-data')
def training_data(principal: Principal = Depends(require_trainer), session: Session = Depends(db_session)):
    return [{'text': ticket.title + '\n' + ticket.description, 'category': ticket.category}
            for ticket in session.scalars(select(Ticket).where(
                Ticket.status == 'completed', Ticket.category_checked.is_(True)).order_by(Ticket.id))]
