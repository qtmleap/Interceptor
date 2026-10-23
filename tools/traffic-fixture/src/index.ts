import { app } from './app'

// Worker entry. The Hono app lives in ./app so tests can import it without the Worker wrapper.
export default {
  fetch: (request: Request) => app.fetch(request),
}
