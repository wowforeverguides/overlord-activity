# Overlord Activity uploader (Windows)

Uploads your Overlord Activity history to this site when you run it (after closing the game). It reads
`World of Warcraft\_forever_\WTF\Account\<ACCOUNT>\SavedVariables\OverlordActivity.lua`,
converts `OverlordActivityDB.history` and `OverlordActivityDB.weekly` to `data/activity.json`
and pushes that one file through the GitHub API. Nothing to install: it runs on the
Windows PowerShell 5.1 that ships with Windows 10/11 (PowerShell 7 works too).

What it publishes: your 15-minute activity buckets, sessions and Overlord's weekly totals.
What it never publishes: the weekly best player's name, your own name from the ranking, and
(by default) your character names, which become "Character 1", "Character 2"...
Remember the site is public: anyone can see when you play.

## 1. Put the files somewhere

Copy the `uploader` folder to e.g. `C:\Users\<you>\Documents\OverlordActivity\`.
If Windows blocks the scripts after downloading, run once in PowerShell:

```powershell
Get-ChildItem "$HOME\Documents\OverlordActivity" | Unblock-File
```

Optional: copy `overlord-upload.config.example.json` to `overlord-upload.config.json` in the
same folder and edit it (game folder, account, repo). Without it the script finds the game
folder and the account by itself (when only one account has the addon's file).

## 2. Create a fine-grained token (only for this repo)

1. GitHub → Settings → Developer settings → Personal access tokens → **Fine-grained tokens** → Generate new token.
2. Name: `overlord-activity uploader`. Expiration: e.g. 90 days (set a reminder to renew).
3. Resource owner: `wowforeverguides`.
4. Repository access: **Only select repositories** → `overlord-activity`.
5. Repository permissions: **Contents: Read and write** (Metadata: Read-only is added automatically). Nothing else.
6. Generate and copy the token (starts with `github_pat_`).

## 3. Store the token (never in the repo, never in a file)

```powershell
cd "$HOME\Documents\OverlordActivity"
powershell -ExecutionPolicy Bypass -File .\set-token.ps1
```

Paste the token when asked (input is hidden). It goes into **Windows Credential Manager**
as `overlord-activity-github` and the script checks that the token can see the repo.
`.\set-token.ps1 -Remove` deletes it again.

Alternative: a user environment variable `OVERLORD_GH_TOKEN` (System Properties →
Environment Variables → User variables). Credential Manager is preferred because the
value is encrypted for your Windows account.

## 4. Upload once, by hand (the only recommended way for now)

Close the game first (it writes `OverlordActivity.lua` on exit), make sure the token is
stored (step 3), then run one upload:

```powershell
cd "$HOME\Documents\OverlordActivity"
powershell -ExecutionPolicy Bypass -File .\overlord-upload.ps1
```

Each run that finds new data makes one commit to `data/activity.json`.

### Automatic uploads (recommended: Watch mode)

Automatic uploads are approved by the owner. Each play session adds one commit to the
repository's main branch. The recommended way is the Task Scheduler job in Watch mode: it
starts at log on, waits in the background (checks every 15 seconds) and uploads each time
the game closes.

```powershell
cd "$HOME\Documents\OverlordActivity"
powershell -ExecutionPolicy Bypass -File .\install-task.ps1            # Watch mode (default)
powershell -ExecutionPolicy Bypass -File .\install-task.ps1 -Remove    # turn it off again
```

Alternatives: `install-task.ps1 -Mode Interval -Minutes 60` (uploads only if the data
changed), or point your desktop shortcut at `Launch WoW and upload.cmd`, which starts the
game and uploads when it closes. Use only one automatic method.

## 5. Test it

```powershell
# 1) convert only, no network; open the JSON to check it
powershell -ExecutionPolicy Bypass -File .\overlord-upload.ps1 -DryRun -OutFile "$env:TEMP\activity.json"
# 2) when the JSON looks right, upload once (as in step 4)
powershell -ExecutionPolicy Bypass -File .\overlord-upload.ps1
```

Then open the site; the yellow "Sample data" banner disappears once your file is live
(GitHub Pages needs about a minute). The log is `%LOCALAPPDATA%\OverlordActivity\upload.log`.

Options (command line or config file): `-WowDir`, `-Account`, `-SavedVariables <file>`,
`-Owner`, `-Repo`, `-Branch`, `-CharacterNames Alias|Keep`, `-Days N` (only the last N days),
`-Force` (upload even if unchanged). `-Launch`, `-Watch` and `-GameExe` belong to the
automatic modes (see step 4).

Notes
- The game writes `OverlordActivity.lua` when you log out or exit, so run the upload after
  the game has closed. A full 180-day history can take 10-30 s to convert.
- Each upload is one commit to `data/activity.json`. Unchanged data is not uploaded again.
- Errors 401/403/404 mean the token is wrong, expired, or lacks Contents: Read and write on this repo.
