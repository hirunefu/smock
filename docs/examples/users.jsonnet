// A Definition file for smock, written in Jsonnet. smock reads JSON, so
// export it first:
//
//   jsonnet users.jsonnet -o defs/users.json
//
// A function writes one Stub per user, and each body is built as a JSON
// value instead of an escaped string.
local getUser(id, name) = {
  id: 'get-user-%d' % id,
  mock: 'users',
  request: { method: 'GET', path: '/users/%d' % id },
  response: {
    status: 200,
    headers: { 'Content-Type': 'application/json' },
    body: std.manifestJsonMinified({ id: id, name: name }),
  },
};

{
  version: 1,
  mocks: [{ name: 'users' }],
  stubs: [getUser(1, 'Alice'), getUser(2, 'Bob'), getUser(3, 'Carol')],
}
