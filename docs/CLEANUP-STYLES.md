# Cleanup styles

Choose a style under **AI Cleanup → Cleanup style**. Offline mode skips all cleanup.

| Style | What it does |
| --- | --- |
| **Faithful** | Removes speech clutter and fixes punctuation while staying close to your wording. |
| **Polished** (default) | Improves grammar and phrasing without losing meaning or details. |
| **Compose** (experimental) | Organizes lists and paragraphs, resolves spoken corrections, and refines the writing. |
| **Custom** (experimental) | Polished cleanup plus your own instructions. |

## Compose

Compose edits the current recording and inserts the finished text when you stop.

- "Meet on Monday, sorry, Wednesday" keeps Wednesday.
- "First save the file, second close the window" becomes a numbered list.
- "New line" and "new paragraph" control spacing when used as layout cues; quoted or discussed cues stay literal.
- Requests you dictate to another person or AI stay requests.
- Lists use plain-text bullets or numbers. Rich text and editing earlier recordings are not supported.
- Language, script, and mixed-language speech are preserved unless custom settings request a change.

Compose uses your selected cleanup model, so quality and timing vary by model. It can miss formatting or corrections, or change meaning; review important text. Higher reasoning, where supported, may help but adds latency and has not been verified in our benchmarks. See the [Compose benchmark checkpoint](COMPOSE-VALIDATION.md).

## Custom instructions

Choose **Custom** to reveal the instructions editor. Add guidance for tone, spelling, terminology, translation, or formatting on top of Polished cleanup.

- Instructions apply only while Custom is selected; other styles hide the editor and keep your text saved.
- Leave the field empty, or choose **Clear**, to use Polished cleanup.
- The limit is 2,000 characters; over-limit edits stay visible but are not saved.
- Changes made while recording apply to the next dictation.
- Instructions are saved locally and sent to your cleanup provider with each Custom dictation. They are not included in routine diagnostic logs.

Custom carries the same experimental caveats as Compose.
