// http.mjs — minimal HTTP driver for the SE harness (node stdlib only).
// Usage: node http.mjs <METHOD> <path> [json-body]
// Prints "STATUS <code>" then the response body (if any) on the next line.
// rc 0 = a response came back (any status); rc 1 = connection failure.
const [method, path, body] = process.argv.slice(2);
const base = process.env.SE_BASE || 'http://127.0.0.1:8000';
try {
  const res = await fetch(base + path, {
    method,
    headers: {
      'content-type': 'application/json',
      authorization: process.env.SE_TOKEN || 'secret',
    },
    body: body === undefined ? undefined : body,
  });
  const text = await res.text();
  console.log(`STATUS ${res.status}`);
  if (text) console.log(text);
} catch (err) {
  console.error(`CONNECT-FAIL ${err.message}`);
  process.exit(1);
}
