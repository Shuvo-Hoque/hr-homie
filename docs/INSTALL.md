# Installing HR Homie

HR Homie is a little colleague who walks onto your screen to remind you to drink water, rest your eyes, stretch
your legs and, in Kuala Lumpur, when it's prayer time. He waits until you answer, so he never just pops up and
vanishes.

Works on macOS 13 or later, Apple silicon and Intel.

## Install (2 minutes)

1. Open **HR-Homie-1.0.0.dmg** and drag **HR Homie** onto **Applications**.
2. Open **HR Homie** from Applications. macOS will say it couldn't verify it, because the app isn't from the App
   Store. Click **Done**.
3. Open **System Settings → Privacy & Security**, scroll down to **Security**, and click **Open Anyway** next to
   "HR Homie was blocked". Enter your password and click **Open**.

You only do step 3 once. After a couple of seconds he walks in and says hi.

Prefer the Terminal? After step 1, this does the same as steps 2–3:

```bash
xattr -dr com.apple.quarantine "/Applications/HR Homie.app" && open "/Applications/HR Homie.app"
```

## Using it

- Everything lives in the **drop** in your menu bar (it fills up as you drink through the day).
- Turn on **Open at Login** in that menu so he's there every day.
- **Reminders**: switch Water, Eye Breaks, Movement Breaks, Prayer Times and Peekaboo on or off.
- When he's waiting: answer **Okay 🙌** or **Not Now**, poke him, or drag him somewhere else.
- In a meeting? **Pause for 1 Hour** or **Pause Until Tomorrow**.

**Can't see the drop?** On a MacBook with a notch, a full menu bar hides the leftmost icons behind it. Just open
**HR Homie** again (from Applications or Spotlight) and its menu pops up right at your mouse pointer. To bring the
drop back for good, hold **⌘** and drag it further right, or hide icons you don't need in **System Settings → Menu Bar**.

## Privacy

Nothing about you leaves your Mac. Your water log and settings stay on this Mac. The only network request is
downloading the official JAKIM prayer timetable for Kuala Lumpur once a year. He doesn't record your screen,
keyboard or camera: he only checks where the mouse is (so clicks on him work) and where your front window is (so he
can sit on it).

## Uninstall

Choose **Quit HR Homie** in the drop's menu, then drag the app from Applications to the Bin.
