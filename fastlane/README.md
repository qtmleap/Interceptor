fastlane documentation
----

# Available Actions

## iOS

### ios beta

```sh
bundle exec fastlane ios beta
```

CI only: build the verified merge commit from a clean copy and upload it to TestFlight.
It refuses to run outside `.github/workflows/testflight.yaml`; see `SETUP.md`.

----

fastlane regenerates this file when documentation is not skipped; CI sets `FASTLANE_SKIP_DOCS=1`.
