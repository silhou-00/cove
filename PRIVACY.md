# Privacy Policy — Cove

**Last updated: August 2, 2026**

Cove is a local-first task manager. All of your data stays on your device — Cove has no backend server, no user accounts, and no analytics or telemetry of any kind.

## Data stored locally

Everything you enter into Cove — tasks, notes, schedules, categories, your app lock PIN — is stored only in a local database file on your device. None of it is ever transmitted anywhere unless you explicitly enable Google Calendar sync (below). Uninstalling the app deletes this data.

## Google Calendar access (optional, off by default)

Google Calendar sync is turned off by default. If you choose to connect it from Settings, Cove requests access to your Google Calendar through Google Sign-In:

- **Read access** (`calendar.events.readonly`) is requested when you connect, so Cove can show your existing Google Calendar events alongside your Cove tasks.
- **Write access** (`calendar.events`) is requested only if and when you turn on an export mode that lets Cove create or delete events on your calendar. This scope is never requested until you actually enable that feature.

Cove only ever reads or writes calendar **event** data — it never requests access to any other Google service (Gmail, Drive, Contacts, etc.). Your connected Google account's email address is stored locally on your device, only to show which account is connected, and is never sent anywhere.

You can disconnect Google Calendar at any time from Settings, which revokes Cove's access to your account.

## Data sharing

Cove does not share, sell, or transmit any of your data to any third party. There is no analytics SDK, no crash reporter, no advertising network, and no server operated by Cove or its developer.

## Changes to this policy

Any change to how Cove handles data will be reflected in this file in the project's repository.

## Contact

Questions about this policy or Cove's data handling: [add your contact email or a link to your GitHub profile here].
