# Explicit Apple policy disclaimer

The App Review follow-up requested an identifiable Apple-policy disclaimer. The reviewed build's existing Purpose, Data Recorded, Storage and Sharing, Certificate and VPN, and Your Choices sections did not have that explicit heading.

The shared data-use view now starts with **Apple Policy Disclaimer** in English and **Appleポリシーに基づく注意事項** in Japanese. It states that explicit consent is required before traffic collection and that captured data is not sold or automatically sent to the developer, analytics services, or third parties. Original Nintendo service communication and user-initiated copying/exporting remain separate flows described in Storage and Sharing / 保存先と共有.

## Reviewer steps

1. Launch without an existing agreement: the mandatory Data Use / データ利用 screen appears.
2. Read the first disclosure card below About Data Use / データ利用について. Its heading is Apple Policy Disclaimer / Appleポリシーに基づく注意事項.
3. If agreement is already saved, open Settings → Privacy / 設定 → プライバシー. The same statement is the first section.
4. Settings → Privacy → Withdraw Consent returns to the mandatory notice. Agreement remains required before the main interface or capture is available.

This clarification does not change data handling or the consent version. It does not install certificates, configure VPN access, start capture, or request notification permission. The five existing disclosure bodies remain unchanged. A replacement build must be verified and selected before reporting these steps as shipped to App Review; the rejected build does not gain this notice through a metadata update.
