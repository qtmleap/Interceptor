# Explicit Apple policy disclaimer

The App Review follow-up requested an identifiable Apple-policy disclaimer. The reviewed build's existing Purpose, Data Recorded, Storage and Sharing, Certificate and VPN, and Your Choices sections did not have that explicit heading.

The shared Data Use & Consent view (identical at startup and in Settings, apart from the Agree / Withdraw action) shows a short neutral introduction, then begins its disclosures with **Apple Policy Disclaimer** in English and **Appleポリシーに基づく注意事項** in Japanese. It states that explicit consent is required before traffic collection and that captured data is not sold or automatically sent to the developer, analytics services, or third parties. Original service communication and user-initiated copying/exporting remain separate flows described in Storage and Sharing / 保存先と共有.

## Reviewer steps

1. Launch without an existing agreement: the mandatory Data Use & Consent / データ利用と同意 screen appears.
2. Read the first disclosure card, directly below the shared introduction. Its heading is Apple Policy Disclaimer / Appleポリシーに基づく注意事項.
3. If agreement is already saved, open Settings → Data Use & Consent / 設定 → データ利用と同意. The same screen and statement appear, with a compact Withdraw Consent button instead of Agree.
4. Settings → Data Use & Consent → Withdraw Consent returns to the mandatory notice. Agreement remains required before the main interface or capture is available.

This clarification does not change the consent version or the meaning of the data-handling disclosure. Opening the notice does not install certificates, configure VPN access, start capture, or request notification permission. The Certificate and VPN paragraph now names Settings → How to Use → Begin Capture Setup, where each setup action remains separate. A replacement build must be verified and selected before reporting these steps as shipped to App Review; the rejected build does not gain this notice through a metadata update.
