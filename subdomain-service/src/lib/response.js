// JSON response helper.

const JSON_HEADERS = {
  "Content-Type": "application/json; charset=utf-8",
  "Cache-Control": "no-store",
};

export function jsonResponse(status, body, extraHeaders) {
  const headers = extraHeaders
    ? { ...JSON_HEADERS, ...extraHeaders }
    : JSON_HEADERS;
  return new Response(JSON.stringify(body), { status, headers });
}
