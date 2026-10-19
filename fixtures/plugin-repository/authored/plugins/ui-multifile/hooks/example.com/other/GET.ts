// SECONDARY HOOK FILE
Interceptor.attach({request: {
  onEnter(req) { req.body.limit = 15; },
  onLeave() {}
}, response: {
  onEnter(res) { res.body.maintenance = false; },
  onLeave() {}
}});
