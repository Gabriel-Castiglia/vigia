# Changelog

## 3.6.0 — 2026-11-27

What Vigía for Windows brought in 3.6.0, where it applies on the Mac.

- **Spanish addresses the reader as *tú*** across the interface, the sample document and the README (it used the
  voseo). The texts that Vigía for Windows has too are now word for word the same. The spelling of Uruguay, with the
  voseo, is still there for the spell check.
- **The editor page has a Content Security Policy**: only the program's own scripts run. It is the same page as Vigía
  3.6.0 for Windows; the Mac serves it with its own addresses (`gm-app://app`, `gm-doc://doc`).
- **Find ignoring case** no longer shifts the mark in a paragraph with a letter whose lower case is longer (such as
  the Turkish «İ»): the text looked for is marked and replaced, not the one beside it.

## 3.5.4 — 2026-11-27

- **The GitHub view follows GitHub in two more cases**, with marked 18.3.0 (it was 15.0.12), the same page as Vigía
  3.5.4 for Windows: a loose tilde used as "about" (`~2 min`, `~234 GB`) no longer strikes out the text up to the next
  tilde, and `**bold**` that starts with code is bold instead of showing its asterisks. Checked by rendering 395 notes
  with both versions: those were the only differences.

## 3.5.3 — 2026-11-27

What Vigía for Windows brought in 3.4.0 to 3.5.3, where it applies on the Mac.

- **A new icon**: a lighthouse drawn as a flat picture, cream with a black outline on the theme colour, with its
  stripes, gallery, lit lantern and two beams; the engraving it replaces read as a candle at small sizes. It still
  follows the colour chosen in *View → Theme…*, in all twelve colours. The drawing is in `assets/icon.svg`.
- **New Markdown file and New folder**, the first two buttons of the toolbar and two entries of a folder's
  right-click menu, with a free name offered; a file without a Markdown extension gets `.md` and its name as a
  heading, and opens at once. Nothing is written over.
- **Delete** (right-click), to the Trash, after a question that can be silenced for that window; where there is no
  Trash it asks again before deleting for good. Its tabs close and it leaves Favourites and Open recent.
- New file, new folder and delete only with the tree unlocked, as dragging; the padlock's tooltip says so.
- The toolbar buttons and the buttons of the Files panel have names for VoiceOver.


What Vigía 3.2.1, 3.3.0 and 3.3.1 for Windows brought, where it applies on the Mac.

- **Spell check in several languages at once**, on by default with English, Spanish, the Spanish of Uruguay and
  Japanese: a word is right when any chosen language knows it. The page marks the words (a red wavy line, code and
  addresses left out) and the Mac's own checker decides, language by language; WebKit's checker followed one
  language and had no ignore list, and is off now. The Spanish of Uruguay is the Mac's Spanish plus the voseo:
  a word it does not know is tried as the vosotros form it comes from (*tenés* → *tenéis*, *mirá* → *mirad*,
  *decíselo* → *decid*). Right click on a marked word: suggestions, *Ignore (until Vigía quits)*, *Add to
  Dictionary*. *Edit → Spell Check Languages and Dictionary…* picks among every language macOS has and lists the
  words added (untick one to take it out).
- **Preview tab**: a click on a file in the Files panel (or Favourites, or Recent) shows it in a passing tab, its
  name in italics, that the next click reuses. Typing in it, saving it under a name, or a double click on the file
  keeps it; *File → Preview Tab for Files from the Panel* turns it off. A file opened from Favourites leaves the
  folders of the panel as they were.
- **Saving**: a document that is a symbolic link was replaced by a plain file with the new text, and the file it
  pointed to kept the old one; the extended attributes (Finder tags and comments) were lost on every save. The new
  text now reaches the disk and takes the old file's place with its permissions and attributes, through the link.
  A read-only file is refused instead of replaced.
- **Undo right after opening a file emptied the document** (the loading of the text was in the undo history), and
  a table whose cells end in inline HTML (`| x <sub>L-02</sub> |`) showed a blank visual view; both fixed in the
  page, as on Windows.
- **A smaller page**: the GitHub view carries the ~40 common highlight.js languages; a code block in any other
  language loads the full set (`lib/hljs-all.js`) only then. Newer libraries in the page: DOMPurify 3.5.0, TOAST UI
  Editor 3.2.3, highlight.js 11.12.0, marked-footnote 1.4.0, github-markdown-css 5.9.0.
- The release carries `release.sig`, the author's signature of its `SHA256SUMS.txt`, like the Windows apps. Vigía for
  Mac already accepts an update only when the downloaded app is signed as the installed one.
- Not taken from Windows: the page started ahead so that new tabs open at once (a new tab is ready in 0.37 to 0.58 s
  on the Mac, measured; 0.8 to 1.2 s on Windows), the error log and the network-picture rule (Windows only).

## 3.2.0 — 2026-11-24

The same as Vigía 3.2.0 for Windows: tabs, Expand all and Japanese.

- Tabs, with the tabs of macOS. Each document keeps its own editor, so its undo history, cursor and scroll
  position stay while another tab is shown; a dot on the close button of a tab marks unsaved changes. Opening a file
  shows the tab that already has it, or opens it in a new tab next to the shown one, or in the shown tab itself when
  it is an untitled document nobody typed in or the sample as it came. That goes for File → Open…, Open recent, a
  click in the Files panel, a link to another Markdown file, the files dropped on the window and the ones the Finder
  sends; several at once open a tab each. Before, a click in the Files panel replaced the open document.
  - ⌘T (File → New Tab) opens an untitled tab; ⌘N (File → New Window) still opens a window. ⌘W closes a tab, asking
    about its unsaved changes. ⌃⇥ and ⌃⇧⇥ switch tabs, and ⇧⌘T (File → Reopen
    Closed Tab) brings back the last one closed. The Window menu shows the previous or the next tab, moves a tab to a
    new window, merges all the windows and shows all the tabs, in the app's language.
  - File → Reopen Tabs at Start (off by default): the next start opens the files of the tabs again, in order,
    with the same tab in front. The list is written as the tabs change, so it survives a crash; quitting or closing
    the last window keeps it. Untitled documents are not kept, and a file that is gone by then is left out. Files
    the Finder asks to open at start are added after them.
  - A tab whose file changes on disk reloads at once, also while another tab is shown, as every window did. Moving
    or renaming files in the Files panel takes their tabs along, and each tab keeps its own recovery draft.
  - An update that installs itself opens every tab again.
- Expand all: the button of the Files panel's header collapses every folder while any is open, and expands them
  all, every level, when everything is closed; its icon and tooltip say which. Also in the panel's ⋯ menu. Expanding
  stops after 1,500 folders.
- Japanese (日本語): menus, toolbar, tooltips, dialogs, panes, the editor's own menus and the theme colours, a
  Japanese sample document and the installer in Japanese. *Language → 日本語*; on a Mac in Japanese it is the language
  from the first start. A Japanese text counts its words with the system's word breaker (a text without spaces
  counted as one word), and Help → Markdown guide opens GitHub's Japanese page. The manual in Japanese is
  `docs/Vigia-manual-ja.pdf` (Help → User manual), made from `README.ja.md`.
- The Files panel's title shows whole or not at all: next to the buttons, a narrow panel cut it to "FI…".
- The sample document, in every language, has a section on tabs.

## 3.1.0 — 2026-11-21

The panes work as on Windows.

- Files and Contents each go to the left or to the right of the text, and two on one side sit one above the other or
  side by side: six layouts, in View → Layout and in the layout button, which moved to the right end of the toolbar
  as on Windows. Its panel draws the six, turns each pane on or off and swaps them.
- A pane is dragged by its title to an edge of the window. While it moves, a guide shows both edges and lights the
  place it would take, with its name (on the left, above Files, to the right of Contents…); Esc cancels.
- Each arrangement keeps its own width. The three layouts of 3.0, with their widths, come over the first time.
- The default theme colour is sky blue, the lighthouse against the sky (it was dark gold), and so is the app's icon.
  A colour chosen before stays.
- The panes have one colour, as on Windows: the lists of Files and Contents painted a grey block of their own,
  shorter than the pane, under headers of another colour.
- The icons of the Files panel take the theme colour (folders) or a muted grey (files), as on Windows. In a window
  in front they took the Mac's own accent colour instead: green icons in a red theme.

## 3.0.0 — 2026-11-20

**Gryphmark is now Vigía**, a name easier to remember: the one who keeps watch from above, as the app watches a
Markdown file while an AI writes it. The same number as Vigía 3.0.0 for Windows. The icon is a lighthouse, from
Debenne's design for a lighthouse (c. 1815, The Met, CC0). The repository is now `vigia` (GitHub forwards the old
address).

- The app is `/Applications/Vigia.app`, with the identifier `io.github.gabriel-castiglia.vigia`; the package is
  `Vigia-<version>.pkg`, and installing it closes and removes Gryphmark.
- The first time Vigía starts, the settings of Gryphmark come over whole, and so do its crash-recovery drafts. Each
  dedicated instance made by Gryphmark ("Name (Gryphmark).app") is made again as a Vigía instance with the same
  folders, home file, colour and start options, and the old one goes to the Trash; each instance brings its own
  settings the first time it opens.
- The texts of the update question name the app as it reads ("Vigía") apart from its file name.

## 2.2.1 — 2026-11-20

The same number as Gryphmark 2.2.1 for Windows. What 2.1.0 and 2.2.0 brought there, as it fits the Mac, and the fixes
of 2.2.1.

- Search in the folders (⇧⌘F, Edit → Search in folders): the box above the tree looks for a file by its name or for
  words inside every Markdown file of the open folders, capitals and accents aside, only what the trees show.
  Results come grouped by file, each line with its number and the match in bold; ↓ ↑ and Return work as in a list.
  A click opens the file at that very match, with the find bar showing it.
- A click on a found line lands on that very match also in the Visual and GitHub views, which hide link addresses
  and tags: the line of the file goes with the click, and when the view holds another number of matches the page
  takes the one whose paragraph shares most words with that line.
- Favourite files and folders: the star of each row, right-click, or File → Favourite. One list for every folder,
  the first block of the Files panel (folders first, each file with its folder in grey); a favourite folder opens
  like a tree. Dragged onto one another, or right-click: Move up, Move down, Sort A → Z, Remove the ones that no
  longer exist, Empty the list. A favourite renamed or moved from the panel follows its file.
- A RECENT block with the last files opened, under the favourites. Off by default: View → Recent Files in the
  Panel, or the panel's ⋯ menu.
- The layout button at the right end of the toolbar, drawn as the current layout, with every layout drawn: no
  sidebar, stacked, side by side and Contents on the right.
- The dividers have a visible handle that takes the accent colour under the pointer; a double click gives the usual
  size back.
- Updates that install themselves (Help → Check for updates, and once a day): one question, then the package is
  downloaded and checked against the release's `SHA256SUMS.txt`, its app checked for the same identifier, version
  and signature, and swapped for the installed one as Gryphmark quits; the new one opens. The dedicated instances
  take it when the main app opens.
- The self-test hides every question in its quiet run and fails if a window or a question was seen.
- The find bar no longer moves to the next match when its text is set to the same words from outside.
- Not brought over from Windows: panes placed anywhere by dragging their title, and the Search pane as a pane of
  its own (on the Mac the search lives above the tree).

## 2.0.0 — 2026-11-16

macOS and Windows now share one version number: this is 2.0.0 on both.

- Pictures work in more places. In the GitHub view a picture can be given by an absolute path (also
  outside the open folders), a `file:` address, with spaces in its path (`![a](my picture.png)`), as
  `![[picture.png]]` or `![[picture.png|300]]` (Obsidian; a name not beside the document is looked for in the open
  folders), and with a size as `![alt|300](a.png)`. A picture that cannot be found is a dashed box with its name
  instead of a broken icon, and a click on a picture opens it in Preview. What the page may load: the document's
  folder, the folders of the Files panel when the document is in one of them, and pictures from anywhere; nothing else.
- Tables fit the column. A long path, address or piece of code inside a cell breaks where it has to, so the
  columns share the width instead of the table hiding behind a scrollbar; plain words stay whole. A table of eight
  columns or more takes less padding in its cells. Measured on 58 notes with such tables: in a 1200 px window, 6
  scrolled before and none now; in an 800 px one, 8 before and 3 now.
- Text width, in View → Text width: *Normal* (980 px, GitHub's column, as before), *Wide* (1280 px),
  *Very wide* (1600 px) or *The whole window*, for the Visual and GitHub views. Printing and exported pages keep
  GitHub's width.
- Three layouts for the sidebar, in View → Layout: *Files above Contents* (as before), *Files and Contents
  side by side* and *Contents on the right of the text*. Each layout keeps its own widths.
- Rename and move from the Files panel: right-click → *Rename…*; with the tree unlocked (the padlock in the panel
  header) files and folders dragged onto a folder are moved there on disk. Two arrows in the header undo and redo
  renames and moves. The open document follows its file, saved first if it had changes, and so does *File → Open
  recent*. A name already taken, a folder into itself and the open folders themselves are refused.
- Properties at the top of a file (front matter, between two `---` lines) are a grey folded box in the Visual
  view and a table under a folded *Properties* line in the GitHub view, saved exactly as written; `+++` (TOML) blocks
  too. A block counts only when it closes and holds a key: a first `---` that never closes, or a file that starts
  with a rule, keeps its text in sight in both views. The Contents list skips the block and keeps `IMG_1915` as
  written.
- Pasting inside a code block no longer splits it: whatever is pasted there goes in as plain text.

## 1.6.0 — 2026-11-14

- **Reading at the end, you follow the end**: when another program adds text at the bottom of the file and you were
  at the end of the view, the view goes down with it, as in a terminal. Anywhere else you stay where you were.
- As on Windows: **File → Open recent** also lists the folders opened lately and the sample (*Hide sample* takes it
  out; *Help → Show sample in Open recent* brings it back); **Copy info** in About copies the version and the system
  for a problem report; the status line has a **zoom slider**.

## 1.5.0 — 2026-11-13

- **What another program changed is marked in green** for a few seconds after a reload, in every view: new or
  rewritten paragraphs, and only the point or row added to a list or a table.
- **An edited line keeps all of itself but your change.** The visual editor rewrote the whole line in its own style
  when one letter of it changed: `\|` and `\.` in a line with a pipe, `*x*` for `_x_`, `\~` for `~`, and inline tags
  such as `<kbd>` were lost. Now only what you typed or deleted changes in the file.

## 1.4.1 — 2026-11-13

- The editor page is now the same file as in the Windows version (checked on every commit). Nothing changes in use.
- The self-test runs out of sight: no Dock icon, no window in front, nothing that takes the focus. `--self-test
  --visible` also runs the two checks that drag the sidebar's dividers, which need the window in front.

## 1.4.0 — 2026-11-13

- **Autosave**, on by default: a file with a name saves itself 1.5 seconds after you stop typing. A switch in the
  toolbar, and File → Autosave, turn it on and off. It never writes over a change made by another program (the
  live reload asks first), and never a new untitled document: that one is saved by itself once it has a name.
- **The scrollbar of the Visual view is at the window's edge.** In a window wider than the 980 px text column it
  stood at the edge of the column, with a wide empty margin to its right. The column is the same width as before.
- Saving takes the text and marks it saved in one step: a key pressed while a save was under way could be left out
  of the file and of the next save.

## 1.3.0 — 2026-11-12

- **The folders of the Files panel work as on Windows.** Each folder has its own colour: tones of the theme colour,
  multicolour, or none, and any folder can take one of twelve colours by hand (right-click its name → Colour).
- **Pin to top**: a pinned folder goes first and shows a pin. **Move up** and **Move down** change the order by hand.
- **The ⋯ button of the Files panel**: order of the folders (order opened, name A → Z or Z → A, recently modified
  first), their colours, and what opens at start.
- **Folders at start** (also in the File menu): reopen the folders of the last session, start clean, or start with
  only the pinned folders.
- The right-click menu of a folder adds *Copy path*; closing a folder also unpins it and forgets its colour.

## 1.2.0 — 2026-11-12

- **The open file stands out in the Files panel**: a filled band in the window's colour (it was only bold), and the
  folders down to it open, as on Windows.
- **Panels of any size**: drag the divider beside the sidebar (180 to 700 points; it was 240 to 420) and the new divider
  between Files and Contents. Each window, and each dedicated instance, keeps the sizes.
- **Convert to TXT**: right-click a file in the Files panel. A .txt is written next to it as the document reads in the
  GitHub view: headings underlined, lists with bullets or numbers, tables in columns, links with their address. The
  Markdown file is not changed, and an existing .txt is never overwritten (`name (2).txt`).
- The Files panel has *Collapse all* (a button and the right-click menu) and *Refresh* in its right-click menus.

## 1.1.2 — 2026-11-12

- A Markdown file with an HTML table whose `<tbody>` is empty (pandoc writes one for every one-row table of a Word
  document) opened as a blank page, with no message. The editor library (TOAST UI Editor 3.2.2) failed on that table;
  its code is now corrected in the bundle, and `scripts/web.sh` corrects it again on every rebuild.
- If the editor library ever fails on a document again, the GitHub view still shows all of it, the visual and Markdown
  views say what happened instead of staying blank, and saving writes the file back exactly as it is on disk.

## 1.1.1 — 2026-11-12

- Installing an update quit every dedicated instance along with Gryphmark, because they run an executable of the
  same name. The installer now quits only the Gryphmark in Applications; the dedicated instances stay open.

## 1.1.0 — 2026-11-11

- **Dedicated instances**, as in the Windows version: a file or folder can open in its own Gryphmark, with its own
  settings, open folders, recent files, window and icon colour. On the Mac each one is an app of its own in
  Applications in your home folder (“Name (Gryphmark).app”, a copy that takes no disk space), so it can stay in
  the Dock. Right-click a file or a folder title in the Files panel → *Open in a dedicated instance*; from the
  command line, `--make-instance "Name"` with `--accent`, `--folder` (one or more), `--home`, `--read-only` and
  `--mode` makes one that always starts read-only and in a given view. Gryphmark rebuilds its instances when it
  is updated, and when their colour was changed from inside them. They never take over Markdown files in the
  Finder.
- **`[[name]]` links** in the GitHub view, as in a wiki: `[[name]]`, `[[name|text]]` and `[[name#heading]]` open
  the Markdown file of that name in the folders of the Files panel or next to the document, the nearest one when
  two share the name. A name that matches no file is shown in red, so broken links can be seen without clicking.
  Editing a paragraph in the visual view no longer escapes its `[[…]]` brackets when saving.
- **Links between the folders of the Files panel**: a document inside one of them can link to, and show pictures
  from, every folder of the panel, and `../` links resolve as on disk. A document opened from anywhere else still
  reaches only its own folder.

## 1.0.1 — 2026-11-10

- The window could be made narrower than its content, which then lost both edges: the toolbar, the sidebar and the
  document were cut off. The window now keeps a minimum size, a saved size that is too small is enlarged, and in a
  narrow window the formatting buttons that do not fit move to a ⋯ menu. A wider window widens the document, not
  the sidebar.
- The app starts with the sample document until you open a file of your own. Before, the sample showed only on
  the very first start.
- Dark theme: list items and table headers in the visual view were almost black on the dark page; they now have
  the colour of the rest of the text (also fixed in Gryphmark 1.8.1 for Windows).

## 1.0.0 — 2026-11-10

First version for macOS, made from Gryphmark 1.8.0 for Windows.

- The same editor page: Visual, Markdown and GitHub views, GitHub alerts, Mermaid, math, footnotes and emoji,
  the HTML of documents cleaned with DOMPurify, saving that keeps the original Markdown, line endings and BOM.
- Live reload in place, with the scroll kept in every view: writes, saves by renaming a new file over the old one,
  deletes and re-creations are followed by kernel file events; the page keeps running behind other windows.
  With unsaved changes the window asks first.
- A native window (AppKit and SwiftUI) per document: toolbar, sidebar with folders and contents, find and
  replace, zoom, export to HTML, print and PDF, crash recovery, update check, Edit and Read only.
- English and Spanish, switched at run time; menus with the macOS shortcuts.
- Theme as macOS, light or dark, and the twelve colours of the Windows version, which also tint the Dock icon.
- Links follow the Windows rules: only web pages, e-mail, Markdown files, pictures and PDFs open; other files are
  shown in the Finder.
- Installer package in English and Spanish, for macOS 15 or later on Apple silicon; `--self-test` in a real
  window.
