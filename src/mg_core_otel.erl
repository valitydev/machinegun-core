-module(mg_core_otel).

%% NOTE tmp
%-include_lib("machinegun_core/include/pulse.hrl").
%-include_lib("opentelemetry_api/include/opentelemetry.hrl").
%-include_lib("opentelemetry_api/include/otel_tracer.hrl").

-type wrapped_ctx(Ctx) :: {otel_ctx, opentelemetry:span_ctx(), Ctx}.
-type maybe_wrapped_ctx(Ctx) :: wrapped_ctx(Ctx) | Ctx.

-export_type([
    wrapped_ctx/1
]).

-export([
    with_current_span_ctx/1,
    set_current_span_from_ctx/1,
    wrap_ctx/2,
    unwrap_ctx/1
]).

%%

-spec with_current_span_ctx(Ctx) -> wrapped_ctx(Ctx).
with_current_span_ctx(Ctx) ->
    wrap_ctx(otel_tracer:current_span_ctx(), Ctx).

-spec set_current_span_from_ctx(maybe_wrapped_ctx(Ctx)) -> Ctx.
set_current_span_from_ctx(Ctx) ->
    {SpanCtx, UnwrappedCtx} = unwrap_ctx(Ctx),
    _ = otel_tracer:set_current_span(SpanCtx),
    UnwrappedCtx.

-spec wrap_ctx(opentelemetry:span_ctx() | undefined, Ctx) -> wrapped_ctx(Ctx) | Ctx.
wrap_ctx(undefined, Ctx) ->
    Ctx;
wrap_ctx(SpanCtx, Ctx) ->
    {otel_ctx, SpanCtx, Ctx}.

-spec unwrap_ctx(maybe_wrapped_ctx(Ctx)) -> {opentelemetry:span_ctx() | undefined, Ctx}.
unwrap_ctx({otel_ctx, SpanCtx, Ctx}) ->
    {SpanCtx, Ctx};
unwrap_ctx(Ctx) ->
    {undefined, Ctx}.
