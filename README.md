# Active-Pitch
An iOS app that makes it easier to find and join pickup soccer game

## Developer setup

The Expo app lives in the `active-pitch/` folder. Run every command below from inside it unless noted otherwise.

### Prerequisites

- [Node.js](https://nodejs.org/) LTS (the project was set up on v24) and npm
- Git
- An [Expo account](https://expo.dev/signup), added to the project's Expo team (Brody will invite)
- Expo Go on your phone
- Access to the Supabase projects (Brody will invite), plus the database passwords/refs Brody will send privately

### 1. Pull the project

```bash
git clone https://github.com/brody-b9801/Active-Pitch.git
cd Active-Pitch/active-pitch
npm install
```

To update later, run `git pull` and then `npm install` again in case dependencies changed.

When adding a package, use `npx expo install <package>` instead of `npm install <package>` so the version matches our Expo SDK.

### 2. Install Expo Go

Install Expo Go from the App Store, and sign in with your Expo account on the phone using the app and in the terminal using:

```bash
npx expo login
```

### 3. Run the app on Expo Go

```bash
npx expo start
```

Scan the QR code in the terminal. If the terminal says it is targeting a development build, press `s` to switch to Expo Go, or start with `npx expo start --go`.

Both devices must be on the same network and that network must let them talk to each other.

#### Campus Wi-Fi does not work: use a hotspot

If campus Wi-Fi blocks devices from reaching each other, the QR code scans but the app hangs or times out while loading. The fix that worked for me is:

1. Turn on the hotspot on your phone
2. Connect your computer to that hotspot
3. Run `npx expo start` and scan the QR code

On Windows, if it still will not connect, allow Node.js through Windows Defender Firewall when prompted, then restart the dev server.

#### Backup: tunnel mode

Tunnel mode sends traffic through a public URL, so the phone and computer do not need to be on the same network. It is slower than a direct connection, but can be used when hotspot is not an option.

```bash
npm i -g @expo/ngrok
npx expo start --tunnel
```

### 4. Before you push

```bash
npx expo lint
npx tsc --noEmit
```

## Supabase migrations

The database schema lives in `active-pitch/supabase/migrations/` as timestamped SQL files. Every schema change goes in a new migration file, never as a manual edit in the Supabase dashboard

### One-time setup

```bash
npx supabase login
npx supabase link --project-ref <project-ref>
```

`login` opens a browser to authorize the CLI with your Supabase account. `link` points your local folder at a remote project and asks for that project's database password. We have a dev project and a main project: link to the **dev** project for day-to-day work. Brody will send the refs and passwords.

### Apply migrations

```bash
npx supabase migration list
npx supabase db push --dry-run
npx supabase db push
```

`migration list` compares local migration files with what the remote project has already run. `db push --dry-run` prints what would be applied without changing anything, and `db push` applies the migrations that are missing remotely.

Run these after any `git pull` that brings in new files under `supabase/migrations/`.

### Create a new migration

```bash
npx supabase migration new <short_description>
```

This creates an empty timestamped file in `supabase/migrations/`. Write your SQL in it, apply it to the dev project with `npx supabase db push`, and commit the file. Do not edit a migration that has already been pushed to a shared project, but add a new one instead.