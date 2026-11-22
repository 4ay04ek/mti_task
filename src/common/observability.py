import logging
import os

from opentelemetry import trace
from opentelemetry._logs import set_logger_provider
from opentelemetry.exporter.otlp.proto.http._log_exporter import OTLPLogExporter
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor
from opentelemetry.instrumentation.sqlalchemy import SQLAlchemyInstrumentor
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor


def configure(app, service_name, engine=None):
    app.root_path = os.getenv('ROOT_PATH', '')
    logging.basicConfig(level=logging.INFO, format='%(levelname)s %(name)s %(message)s')
    if os.getenv('OTEL_SDK_DISABLED', '').lower() == 'true':
        return
    endpoint = os.getenv('OTEL_EXPORTER_OTLP_ENDPOINT', 'http://otel-collector:4318').rstrip('/')
    resource = Resource.create({'service.name': service_name})
    traces = TracerProvider(resource=resource)
    traces.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(endpoint=f'{endpoint}/v1/traces')))
    trace.set_tracer_provider(traces)
    logs = LoggerProvider(resource=resource)
    logs.add_log_record_processor(BatchLogRecordProcessor(OTLPLogExporter(endpoint=f'{endpoint}/v1/logs')))
    set_logger_provider(logs)
    handler = LoggingHandler(level=logging.INFO, logger_provider=logs)
    handler.addFilter(lambda record: not record.name.startswith(('opentelemetry', 'httpx', 'httpcore', 'urllib3')))
    logging.getLogger().addHandler(handler)
    for name in ('opentelemetry', 'httpx', 'httpcore', 'uvicorn.access'):
        logging.getLogger(name).setLevel(logging.WARNING)
    FastAPIInstrumentor.instrument_app(app, excluded_urls='/health')
    HTTPXClientInstrumentor().instrument()
    if engine is not None:
        SQLAlchemyInstrumentor().instrument(engine=engine)

    @app.middleware('http')
    async def request_log(request, call_next):
        response = await call_next(request)
        route = request.scope.get('route')
        logging.getLogger(service_name).info('%s %s %s', request.method,
                                            getattr(route, 'path', 'unmatched'), response.status_code)
        return response
