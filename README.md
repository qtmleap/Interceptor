## Interceptor

自己証明書を利用してNintendo Switch Onlineから`bulletToken`を取得するiOSアプリケーションです

### Requirements

- Xcode 16.x
- fastlane

### Build

TrollStore向けとApp Store/TestFlight向けのプロファイルを用意していますが、特に問題がなければリリースされているipaをSideloadでインストールする方が楽だと思います

#### For TrollStore

`fastlane build`

#### For App Store/TestFlight

`fastlane beta`