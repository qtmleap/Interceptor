Interceptor.attach({request: {
  onEnter(req) { req.body.limit = 5; },
  onLeave(req) {
    if (!req.body || typeof req.body !== 'object' || !('limit' in req.body) || req.body.limit !== 5) {
      throw new Error('SDK request leave needs forwarded JSON');
    }
  }
}, response: {
  onEnter(res) {
    const req = res.request.body;
    if (!req || typeof req !== 'object' || !('limit' in req) || req.limit !== 5) {
      throw new Error('SDK response needs forwarded request JSON');
    }
    res.body.maintenance = true;
    res.body.requestLimit = req.limit;
  },
  onLeave(res) {
    const body = res.body;
    if (!body || typeof body !== 'object' || !('maintenance' in body) || body.maintenance !== true) {
      throw new Error('SDK response leave needs forwarded JSON');
    }
  }
}});
