// PRIMARY HOOK FILE
Interceptor.attach({request: {
  onEnter(req) { req.body.limit = 5; },
  onLeave() {}
}, response: {
  onEnter(res) { res.body.maintenance = true; },
  onLeave() {}
}});
