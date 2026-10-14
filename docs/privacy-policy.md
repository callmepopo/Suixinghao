# Suixinghao Privacy Policy

Effective date: October 13, 2026

Suixinghao (随行号), provided by Junpo Xu, connects your iPhone to a compatible cellular calls and SMS server that you choose and operate. A separate server, cellular module and carrier subscription are required. This policy covers the iOS app and the official push relay. Your server operator, carrier and Apple also process data under their own policies.

## Calls and messages

The app sends dialed numbers, SMS recipients and messages to your configured server to perform the actions you request. Call audio travels between your phone and that server. SMS content and cellular device information are retrieved from your server for display. The official push relay does not receive phone numbers, SMS content, contacts or call audio.

Your server stores SMS and may store call recordings if its administrator enables recording. Recordings require the consent of call participants where applicable. Retention and backups are controlled by that server operator. The supplied server limits each recording to one hour and rotates the active recording directory at 1 GiB; backups may have different retention.

## Data on your iPhone

The service address, App Key and recent call history are stored in this device's Keychain. The app keeps up to 200 local call records, grouped by server. SMS content is not stored in a persistent app cache. With your permission, contacts are used on the phone for number searches and caller name matching; the app does not upload your address book.

Disconnecting retains your saved connection settings so you can reconnect. To remove them, use the app's clear-configuration control. Local call history can be cleared in the app. Removing the app may not remove Keychain entries; use the app's clear controls first.

## Notifications and diagnostics

Your server stores Apple push notification tokens with the authorization for your phone. The official relay receives the token, push environment and, for incoming calls, a random call identifier. It forwards a fixed incoming-call or new-SMS notification to Apple. It does not store raw tokens or message content. Short-lived in-memory token/event hashes are kept for up to five minutes for duplicate prevention, with limited counters for rate limiting. Backend authorization records, including revoked records, remain in the private authorization ledger until administratively removed. The relay receives connection IP addresses as part of HTTPS delivery; its application and proxy do not retain request access logs.

Connection diagnostics on your phone and server contain status, timestamps, counts, signal information and numerical audio transport measurements. They are used for reliability and troubleshooting, not advertising. They exclude SMS text, phone numbers, raw credentials and recorded speech. The supplied server keeps connection events for at most 30 days, subject to size limits; numerical call diagnostics and backups are managed by your server operator.

Development builds may also keep up to 96 local audio-route diagnostic events in the app cache. These contain standard port types, session options, running state and elapsed times, without device names or identifiers, credentials, phone numbers or audio. They are not uploaded. The oldest events are replaced, iOS may remove cached data, and this route file is disabled in release builds.

## Optional automatic push enrollment

If your NAS administrator requests automatic enrollment and you confirm in the official app, the publisher stores your chosen label, a random NAS instance identifier and public key, the push environment, issuance and expiration times, and authorization lifecycle records. The label is self-reported; no real name or email is required and enrollment is not automatically matched to a TestFlight email. Apple App Attest verifies the application; the publisher retains its opaque proof key identifier, public key and assertion counter for verification and binding limits. Apple processes the attestation under its policies. No NAS administrator password, phone App Key or hardware serial is sent to the publisher.

Pending challenges expire after ten minutes. Signed request nonce hashes are retained for up to two minutes and pruned on later requests. Authorization records retain their issuance metadata and the latest 128 lifecycle events, including revocation, to prevent retry-based reactivation. They contain credential hashes; a separate protected server secret permits authenticated recovery of an automatic credential. The NAS stores its instance secret and received credential privately. Publisher administrators may export authorization metadata to private management materials, without credentials or attestation keys. Backups may retain earlier records. Contact the maintainer privately for removal; do not publish identifiers or credentials in support issues. Removing anti-abuse records can affect re-enrollment controls.

## Permissions and sharing

Microphone access is used for calls. Contacts access is optional for local matching. Notification permission is used for call and SMS alerts. The app has no advertising SDK, does not access the advertising identifier, and does not sell data or track you across other companies' apps or websites. Data is shared with your selected server, your carrier and Apple as needed to provide the features you use. The relay uses a hosting provider to deliver HTTPS service.

## Your choices and deletion

You can revoke permissions in iOS Settings, clear local history or configuration in the app, and delete individual SMS or entire SMS conversations from your server through the app. Deleting SMS affects the shared server mailbox and other connected devices. Your server administrator can revoke your App Key, which also removes its registered push tokens and connection-history entries. Ask that administrator about recordings, diagnostic files and backups. The app does not create a publisher-hosted user account.

## Support and changes

For questions about the app or official relay, contact the maintainer through [Suixinghao support](https://github.com/callmepopo/Suixinghao/issues). Do not post App Keys, personal numbers, message content or recordings in public issues. For data retained by your own server, contact its operator. Material changes to this policy will be published here with an updated effective date.
