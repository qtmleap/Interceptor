## Interceptor

A general-purpose iOS tool for inspecting network traffic using a self-signed certificate.

### Requirements

- iOS 16.x
- Xcode 16.x
- fastlane

## Plugin author documentation

Japanese Plugin author documentation is in `docs/site/`. It targets the development
preview on Interceptor `develop` at `d3b9e05db68cd4283a9874df6629313ad39174d5`:
repository import, source editing and explicit QuickJS runs with synthetic input.
Live capture hooks and Webhook delivery are future work. This older working
checkout contains the docs tooling; it does not contain that preview runtime.
Internal design and planning documents in `docs/superpowers/` are excluded from the site.

Plugin authors can generate packages, Ed25519 keys and signed repository metadata
with Bun, using the downloadable example in the distribution guide. Xcode and Swift
are needed for native app development, not for this authoring workflow.

Use [Bun](https://bun.sh/docs/installation) 1.4.2 from the repository root:

```sh
bun install --frozen-lockfile
bun run docs:dev
```

The development server binds to `127.0.0.1`. Build and inspect the static site with:

```sh
bun run docs:build
bun run docs:preview
```

Run `bun run docs:test` to check the standalone Bun repository-generation example.

The preview also binds to `127.0.0.1` and uses Vite's static preview server
(VitePress 1.6's preview command does not support host binding).

Output: `docs/site/.vitepress/dist/`. Configuration:
`docs/site/.vitepress/config.mts`. The site uses [VitePress](https://vitepress.dev/)
1.6.4 with local search. Bun runs the documentation tooling, not the app's Plugin
runtime. When hosting under a subpath, set VitePress `base` for that destination
before building, and pass the same path to preview (for example,
`bun run docs:preview --base /Interceptor/`). No hosting or publishing is configured.

## Contributors

- [zhxie](https://github.com/zhxie)
- [ultemica](https://github.com/ultemica)

## License

Interceptor is licensed under [the MIT License](/LICENSE).
