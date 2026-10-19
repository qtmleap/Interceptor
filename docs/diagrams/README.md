# Plugin Hook diagram

Edit `plugin-hooks.ts`, then run `bun run docs:diagrams` from the repository root.
The Bun script generates light and dark SVGs with identical geometry. Keep the
source and generated SVGs together. No D2 installation, font download or image
generation service is needed. Text uses the viewer's system fonts.

The client, Interceptor and server appear once. Request and response occupy
separate lanes. Blue cards sit before forwarding and allow changes; dashed side
branches show local post-forwarding callbacks. These branches do not originate
from the destination actor and do not represent receipt acknowledgements.
The figure shows conceptual positions, not a total execution order across
request and response streams. All four Hooks are unimplemented API designs.
Manual execution through Shortcuts is explained separately in the page text.

`bun run docs:build` uses the saved SVGs without regenerating them.
