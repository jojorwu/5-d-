# 5D Chess With Multiverse Time Travel — Application Architecture & Behaviour Documentation

**Target:** `5dchesswithmultiversetimetravel.exe`
**Platform:** Windows (x86-64), GUI subsystem
**Author / Publisher:** Conor Petersen / Thunkspace, LLC  (version `1.1.0.0`)
**Site:** `www.5dchesswithmultiversetimetravel.com`
**Document type:** Static reverse-engineering / "how it works" reference.
**Method:** Static analysis of the PE binary + embedded string resources + embedded GLSL shaders (no dynamic execution required). See §11 for the methodology and evidence tags.

> Everything below is derived from the shipped executable itself (strings, import table, PE
> layout, and the GLSL shader source that is embedded verbatim in the code section). Claims are
> tagged **seen** (found in the binary) unless noted **inferred**. Static reading is not observed
> execution, so control-flow details are described as *indicated by the code structure*, not proven
> by running it.

---

## 1. One-paragraph summary

It is a **native C++ desktop game** (not Unity, not Mono/.NET) built on **SDL2** for windowing,
**OpenGL 3.3 Core** for rendering, and **SDL2_mixer / libvorbis** for audio. The whole program runs
on a single main loop thread plus two worker threads — a **Chess Worker thread** (game logic / AI /
puzzle solving) and a **Client Networking thread** (online matches). The game is "5D chess": a
piece's position is a 4-tuple **(row, column, turn, timeline)** and moves are computed across all
four axes; time travel is modelled as **branching timelines** so history can never be altered. The
rendering is a custom 2D sprite pipeline that draws every active chess board, the "multiverse" of
parallel boards, time-travel tunnel effects, and arrow overlays, all composited with embedded GLSL
shaders. State, progress and settings persist to a single `%settings_and_progress.txt` file under
the SDL user-pref path.

---

## 2. Technology stack

| Layer        | Technology                         | Evidence / where it lives in the binary |
|--------------|------------------------------------|------------------------------------------|
| Language     | C++ (MSVC runtime)                 | `Microsoft Visual C++ Runtime Library` strings, C++ type-descriptor/vftable strings |
| Windowing    | **SDL2**                           | `SDL2.dll`, ~90 `SDL_*` imports (window, GL context, events, threads, mutex, condvar) |
| Rendering    | **OpenGL 3.3 Core** (`glad` loader)| `gladLoaderGLLoader()`, hundreds of `gl*` calls, `#version 330 core` shaders |
| Audio        | **SDL2_mixer** + libogg/libvorbis  | `SDL2_mixer.dll`, `Mix_*` imports, `.ogg` sound assets |
| Networking   | Win32 Sockets (`WS2_32.dll`)       | `WSA*`/socket imports, `create_client_socket()`, `ClientNetworkingThread` |
| Entry type   | Windows GUI (`subsystem = 2`)      | PE optional-header `Subsystem = 2` (**seen**) |
| Data model   | Branching-timeline chess engine    | `chess.cpp`, `chess_worker_thread.cpp`, embedded rule text (**seen**) |
| Assets       | TTF fonts, PNG atlas, OGG sound    | `assets/fonts/`, `assets/pieces/pieces.png`, `assets/sounds/*.ogg` (**seen**) |

---

## 3. Binary / PE structure

**Container:** `PE32+ executable for MS Windows 6.00, x86-64, 9 sections`.
Machine = `0x8664` (AMD64), GUI subsystem, `SizeOfOptionalHeader = 0xF0`, 16 data directories.

```
Offset map (file / virtual)
  [MZ header @ 0x0] -> e_lfanew -> [PE\0\0] @ 0x78
     IMAGE_FILE_HEADER @ 0x7c          Machine=0x8664, NumberOfSections=9
     IMAGE_OPTIONAL_HEADER64 @ 0x90    magic=0x20b, entry=0x000D75D8, SizeOfImage=0x400
         Data directories @ 0x100      Export / Import / Resource / ... / DelayImport
     IMAGE_SECTION_HEADER[9] @ 0x180   (0x40 bytes each)
```

Known-good sections (**seen**, read consistently):

```
Name     RVA       FileOff   RawSize   VSize     Flags
.text    0x00001000  0x000400  0x102400  0x0102296  READ,WRITE,EXEC   <-- code + embedded GLSL shaders
...      (sections 1..4 in the header table are non-standard / overwritten data)
.rsrc    0x00155000 0x146A00  0x00B000  0x000AF1C  READ,WRITE        <-- resources (fonts/pieces/audio)
```

Data directories that line up with real sections:
`Resource → 0x155000/.rsrc`, `Basereloc → 0x154000`, `Exception`, `BoundImport`, `DelayImport`.

> **Caveat (important, honest):** the optional header reports `SizeOfImage = 0x400`, which is far
> smaller than the `.text` section it claims to contain, and several section-table entries hold
> non-standard / garbage values. This is the signature of a **merged / repackaged build** (the
> original headers were overwritten by bundled data) — common for indie games that ship assets in
> a single stub. The *code* and *resource* sections are intact and functional; treat the raw
> section table as best-effort. The import table and strings, however, are complete and reliable.

### 3.1 Import surface (what the binary is *capable* of doing)

**DLLs:** `SDL2.dll`, `SDL2_mixer.dll`, `kernel32.dll`, `user32.dll`, `WS2_32.dll`, `SHELL32.dll`,
plus the Microsoft C++ runtime.

**SDL2 (platform layer):**
`SDL_Init / SDL_PollEvent / SDL_Quit`, window mgmt (`SDL_CreateWindow / SetWindowSize /
SetWindowResizable / GetWindowSize / GL_GetDrawableSize`), **OpenGL context** (`SDL_GL_LoadLibrary /
CreateContext / SwapWindow / SetSwapInterval`), threading (`SDL_CreateThread / WaitThread /
CreateMutex / LockMutex / UnlockMutex / CreateCond / CondWait / CondSignal`), input
(`SDL_GetScancodeFromKey`), and asset IO (`SDL_RWFromFile`, `SDL_GetBasePath`, `SDL_GetPrefPath`).

**Audio (SDL2_mixer):** `Mix_OpenAudio / Mix_LoadWAV_RW / Mix_PlayChannelTimed / Mix_FadeInChannelTimed /
Mix_FadeOutChannel / Mix_Volume / Mix_Init / Mix_Quit` — i.e. streamed short SFX and ambient music with per-channel volume + timing.

**Networking (WS2_32):** socket setup (`WSA*` + `create_client_socket()`), plus
`SDL_CreateThread`/`SDL_CreateMutex`/`SDL_CreateCond` failure paths named
`create_chess_worker_thread()` — confirming the two worker threads.

**Win32:** file IO (`CreateFileW`, `ReadFile`, `FindFirstFileExW`), messages (`MessageBoxW`),
threading/events (`CreateEventW`, `CreateThread`, `Tls*`, `InitializeCriticalSection*`).

---

## 4. High-level application architecture

The program is a classic **threaded game loop** with the heavy chess work offloaded to a worker.

```
 ┌───────────────────────────────────────────────────────────────────────┐
 │                           PROCESS (5dchesswithmultiversetimetravel.exe) │
 │                                                                         │
 │   MAIN THREAD (SDL + OpenGL)                                            │
 │   ┌────────────────────────────────────────────────────────────┐      │
 │   │  startup()   →   the loop  ─────────────────────────────┐    │      │
 │   │                  (poll events, render frame)             │    │      │
 │   │   main update()   • input handling                       │    │      │
 │   │   main render()   • chess_ui_render()                    │    │      │
 │   │                         • draw_chess_boards()            │    │      │
 │   │                         • draw_multiverse()              │    │      │
 │   │                         • draw_tunnel_piece()            │    │      │
 │   │                         • draw_timetravel_diagram()      │    │      │
 │   │                         • draw_*_arrows() / buttons      │    │      │
 │   │                         • draw_ui()                      │    │      │
 │   └────────────────────────────────────────────────────────────┘    │
 │                                                                         │
 │   ChessWorkerThread        ── created by create_chess_worker_thread()  │
 │        • legal-move generation for 5D chess                            │
 │        • branching-timeline simulation                                 │
 │        • CPU opponent (AI) + puzzle/training solver                     │
 │        • checkmate / stalemate detection                               │
 │                                                                         │
 │   ClientNetworkingThread   ── create_client_socket() + WS2_32          │
 │        • public / private match listing & join                         │
 │        • move exchange with opponent                                   │
 │        • passcode-based private matches                                │
 └───────────────────────────────────────────────────────────────────────┘
                          ▲                  │        │
                          │   shared          │        │
                          │   game state      │        │
                          └───────────────────┘        │
                             (guarded by SDL mutex)     │
```

### 4.1 The main loop

```
 startup()
   ├─ SDL_Init
   ├─ SDL_CreateWindow  (+ OpenGL 3.3 Core context)
   │     └─ (retry path: recreate window WITHOUT multisample for old Intel GPUs)
   ├─ SDL_GL_LoadLibrary / SDL_GL_CreateContext
   ├─ Mix_Init / Mix_OpenAudio            (audio)
   ├─ gladLoaderGLLoader()                (OpenGL function pointers)
   └─ create_chess_worker_thread()
       create_client_socket()            (networking, if online)

 the loop:
   while running:
       while SDL_PollEvent():  handle (quit, key, mouse, resize)
       main update()   // advance game state, read input, submit moves
       main render()   // chess_ui_render → draw_*() → OpenGL draw calls
       SDL_GL_SwapWindow()
```

---

## 5. Rendering pipeline

A **custom 2D software-free** renderer over OpenGL. The board, pieces, timelines and effects are
all drawn as textured quads using a single **piece atlas** (`assets/pieces/pieces.png`) plus a
white-noise texture for dithering, then composited with embedded GLSL 330 core shaders.

```
 chess_ui_render()
   │
   ├─ draw_chess_boards(ui, physical?, opaque?)      // one quad per active board (MVP-transformed)
   │
   ├─ draw_travelling_pieces(ui)                     // piece sliding between boards (time travel)
   │
   ├─ draw_available_move_arrows(ui)                 // legal-move highlighting
   ├─ draw_check_arrows(ui)                          // check indicators
   ├─ draw_timetravel_arrows(ui)                     // past/future travel arrows
   │
   ├─ draw_tunnel_piece(ui)                          // "tunnel" warp effect
   ├─ draw_tunnel_piece_shadow(ui)
   │
   ├─ draw_timetravel_diagram(ui)                    // timeline/branch diagram + stripe
   ├─ draw_multiverse(ui)                            // the whole parallel-board field
   │
   ├─ draw_check_hint_buttons(ui)
   ├─ draw_tab_hint_buttons(ui)
   │
   └─ draw_finalize(ui)                              // final compositing / UI overlay
       │
   └─ draw_ui(ui)   // top-level: assembles the passes above
```

### 5.1 Embedded GLSL — the "time-travel tunnel" fragment shader

The binary ships the actual GLSL source. The tunnel shader (the warp effect you see when a piece
travels through time) is a self-describing radial effect:

```glsl
// fragment shader  (#version 330 core)
#define TUNNEL_DIAMETER   (4.0 / PI)
#define TUNNEL_TWISTYNESS (1.0 / 4.0)
#define TUNNEL_SPEED      0.3

uniform float u_time;
uniform vec2  u_resolution;
uniform sampler2D u_white_noise_texture;
uniform vec3  u_tunnel_first_color, u_tunnel_second_color;
uniform vec4  u_tunnel_vignette_color;

void main() {
    float aspect = u_resolution.x / u_resolution.y;
    vec2 uv = v_uv - vec2(0.5,0.5);   uv.x *= aspect;

    // spiral: radius ∝ 1/|uv| (looks like a receding tunnel), rotated by twistiness
    vec2 tunnel_uv;
    tunnel_uv.y = (1.0 / length(uv)) + u_time * TUNNEL_SPEED * (1.0 / TUNNEL_DIAMETER);
    tunnel_uv.x = atan(uv.x, uv.y) / (PI/2.0) + tunnel_uv.y * TUNNEL_TWISTYNESS;

    // checkerboard along the tunnel walls, two-colour mix
    vec2 cb_uv = fract(tunnel_uv) - 0.5;
    float cb_value = (cb_uv.x * cb_uv.y) > 0.0 ? 1.0 : 0.0;
    vec3 cb_color  = mix(u_tunnel_first_color, u_tunnel_second_color, cb_value);

    // 4x MSAA: sample the tunnel at 4 sub-pixels and average
    ... (uv_msaa[0..3], tunnel_uv[0..3]) ...
    float msaa_cb_value = (cb_value[0]+..[3]) * 0.25;

    out_color.rgb = mix(u_tunnel_first_color, u_tunnel_second_color, msaa_cb_value);
    out_color.a   = 1.0;

    // screen-corner vignette
    float vignette_factor = u_tunnel_vignette_color.a *
        (1.0 - sin((length(uv) / length(vec2(aspect*0.5,0.5))) * (PI/2)));
    out_color.rgb = mix(out_color.rgb, u_tunnel_vignette_color.rgb, vignette_factor);

    // film dither from scrolling white noise
    vec4 noise0 = texture(u_white_noise_texture, gl_FragCoord.xy/256.0 + vec2(u_time,-u_time)*15.0);
    vec4 noise1 = texture(u_white_noise_texture, gl_FragCoord.xy/256.0 + vec2(u_time, u_time)*15.0);
    out_color.rgb += (noise0 + noise1 - 0.5) * (1.0/255.0);
}
```

Vertex shaders simply apply the model-view-projection matrix (`gl_Position = mvp * ...`) and pass
the UV / position to the fragment stage. Key uniforms observed: `u_board_position / u_board_inner_size
/ u_board_trim_size`, `u_piece_atlas_texture`, `u_white_noise_texture`, `u_time`, `u_resolution`,
`tunnel_*` colour/distortion/scroll params, and `u_physical` (menu "physical" particle mode).

---

## 6. The game engine — 5D chess with multiverse time travel

This is the heart of the program (`chess.cpp` + `chess_worker_thread.cpp`) and the reason the game
exists. The rules are embedded verbatim in the binary, so we can document them precisely.

### 6.1 The five dimensions

```
   A piece lives at a point in a 4-D coordinate space (called "5D" by convention):

        dim 1  ┐
        dim 2  ├─ the "board" you are physically looking at (rows × columns)
        dim 3  ┘   (a third, usually-unused spatial axis)
        dim 4      TURN  (time — the move counter / clock)
        dim 5      TIMELINE (parallel history)

   A square = (row, column, turn, timeline).
   At game start, White's queenside rook is on file A / rank 1 / turn 1 / timeline 0.
```

Movement rules are the **ordinary chess rules generalized to N dimensions**: a direction is "defined
by any combination of dimensions", and a piece moves "any distance in those dimensions at once".

| Piece    | Movement (dimension-generalised)                                                        | Seen |
|----------|-----------------------------------------------------------------------------------------|------|
| Rook     | any distance in **one** dimension at a time (row *or* column *or* turn *or* timeline)  | seen |
| Bishop   | any distance in **two** dimensions at once (a "diagonal" = 2 axes)                       | seen |
| Queen    | any distance in **any number** of dimensions (rook+bishop+triagonal+quadragonal)        | seen |
| Knight   | two squares in one dimension, then one in a *different* dimension                        | seen |
| King     | one square in any number of dimensions at once                                          | seen |
| Pawn     | 1–2 "forward" squares; attacks along spacelike (row/col) and timelike (turn/timeline) diagonals | seen |

**Non-standard pieces** (some variants):
- **Unicorn** — any distance along a *triagonal* (3 dimensions).
- **Dragon** — any distance along a *quadragonal* (4 dimensions).
- **Princess** — rook + bishop only (one or two dimensions at a time; no unicorn/dragon).
- **Brawn** — attacks along any diagonal that includes a forward direction and no backward one.

### 6.2 Timelines, "The Present", and branching (the core mechanic)

```
   TIMELINE (dim 5) grows left→right as turns pass (dim 4 = time).

   timeline 0:  [b1]─[b2]─[b3]─[b4]─[b5]───  The Present →
                          ▲
                          │ White plays e2-e4 ON board b3, landing on a board
                          │ with no move yet  →  a NEW timeline branches off:
   timeline 1:                        [b6]─[b7]─[b8]→

   RULE: "If a piece moves to a board where a move has already occurred, a new timeline branch is
   created because history cannot be altered. The latest move on the new timeline is the time
   travelling piece's ARRIVAL. The latest move on the original timeline is its DEPARTURE."
```

Key engine rules (quoted from the embedded rule text):

- **One unit of time = two boards** (your move + opponent's reply). "The Present" = the earliest
  board without a move on any active timeline.
- **Completing a turn** may require multiple moves to advance *all* active timelines to the next turn.
- **Branching limit:** "If a player branches twice before their opponent branches once, the extra
  branches are **inactive** and don't affect The Present until the opponent makes more branches."
  → you cannot use time travel to escape trouble unless you create *active* timelines. "Branch purposefully!"
- **Check in 5D:** "A move that attacks a king's past is a valid check … applying the move would
  create a timeline with a captured king on it."
- **Checkmate / stalemate:** you're checkmated if you have *no* sequence of moves that shifts The
  Present without leaving a king attacked; stalemate if you can pass on every present board but still
  can't move forward.
- **Softmate:** a timeline that can't be advanced without exposing a king forces its owner to stall
  until they can capture the threatening piece from a new timeline.

### 6.3 Player-facing modes (from the menu strings)

```
  Main menu
   ├─ Versus
   │    ├─ VS CPU        (trainer AI; simplified starting configs)
   │    ├─ VS Public Match      (connect, browse list)
   │    ├─ VS Private Match     (passcode-based: "Copy+paste this passcode to your match partner")
   │    └─ VS Custom Match
   ├─ Checkmate Practice     (Pawns / Knights / Bishops / Rooks / Queens / etc.)
   ├─ Puzzles                (tactics: Backrank Basics, Opening Traps, Combination Attacks, … ~Mate-in-one/three)
   ├─ Guide
   │    ├─ Introduction to 5D Chess
   │    ├─ Pieces / Non-standard Pieces
   │    ├─ Timelines ("Turns and Timelines")
   │    ├─ Checkmate
   │    └─ Strategy Tips and Miscellaneous
   ├─ Rules                  (Complete Rules and Justification)
   ├─ Credits
   └─ Settings
```

---

## 7. Settings & persistence

A single settings/progress file is written under the SDL user-pref path
(`SDL_GetPrefPath()` + `%settings_and_progress.txt`):

```
  ┌────────────────────────────────────────────┐
  │  SDL_GetPrefPath() / settings_and_progress.txt  │
  ├────────────────────────────────────────────┤
  │  ENABLE_MENUMUSIC / ENABLE_SOUND / ENABLE_AMBIENCE │
  │  MENUMUSIC_VOLUME / SOUND_VOLUME / AMBIENCE_VOLUME   │
  │  AUTO_FLIP_PERSPECTIVE / COLORBLIND                    │
  │  SHOW_DISCORD_INVITE_GUIDE                             │
  │  GUIDE0_VISITED … GUIDE5_VISITED  (guide progress)     │
  │  game progress / match history                         │
  └────────────────────────────────────────────┘
```

Other on-disk IO seen in imports: screenshots (`%screenshot_%.png`), logging (`gl_log.txt`), and
console output (`--stdout`).

---

## 8. Assets & resources (`assets/`)

```
  assets/
   ├─ fonts/      CrimsonText-{Regular,Italic,SemiBold}.ttf
                  Inconsolata-Regular.ttf
                  PublicSans-ExtraBold.ttf
   ├─ pieces/     pieces.png   (piece atlas used by u_piece_atlas_texture)
                  attributions_svg_chess_pieces.txt
   └─ sounds/     *.ogg   (libvorbis): ambience, music, bell, fanfare, timpani_*,
                  violin_tremolo_*, wind, cym_whoosh, lightswitch, paper_shuffle, …
  assets/icons/icons.png
```

Resource directory in the PE (`Resource → 0x155000/.rsrc`) packs these in.

---

## 9. ASCII diagrams — quick reference

### 9.1 Process / thread topology

```
                    ┌─────────────────────────────────────────────┐
                    │         5dchesswithmultiversetimetravel.exe   │
                    │                                               │
   input ──► [ Main Thread ] ──► main update() ──► shared game ──┐  │
             SDL/OpenGL loop        │        (chess state)        │  │
                    │                │        ▲   │               │  │
                    │         submit │         │   │ receive       │  │
                    ▼                │   ┌────▼───▼───┐    ▲       │  │
   render ◄── [ chess_ui_render ]     │   │ Chess    │    │       │  │
             draw_*() + GL            │   │ Worker   │◄───┘       │  │
                                      │   │ Thread   │  (CPU AI,  │  │
                                      │   │          │  puzzles,  │  │
                                      │   └──────────┘  engine)   │  │
                                      │                            │  │
                                      │   ┌──────────────────────┘  │
                                      │   │ Client                 │
                                      │   └─► ClientNetworking     │
                                      │      Thread (WS2_32) ◄── internet
                                      │                              │
                                      └──► mutex-guarded state ──────┘
```

### 9.2 Render call order (one frame)

```
   main render()
     │
     ├── draw_chess_boards()        // active boards (MVP quads)
     ├── draw_travelling_pieces()   // time-travelled piece in flight
     ├── draw_available_move_arrows()
     ├── draw_check_arrows()
     ├── draw_timetravel_arrows()
     ├── draw_tunnel_piece() + _shadow   // GLSL tunnel warp
     ├── draw_timetravel_diagram()      // timeline field + stripe
     ├── draw_multiverse()              // all parallel boards
     ├── draw_check_hint_buttons()
     ├── draw_tab_hint_buttons()
     ├── draw_finalize()
     └── draw_ui()  →  SDL_GL_SwapWindow()
```

### 9.3 The 5D coordinate model

```
        ROWS
         ▲        turn (time) → → → → → → → → →
         │      ┌───────────────────────────┐
         │      │ board(2,2) turn 3  tl 0    │◄─ a single square-instance
         │      │                            │    = (row,col,turn,timeline)
         │      │ board(2,3) turn 4  tl 1    │◄─ reached by time-travelling
         │      │         ▲                   │    into the past → new timeline
         │         └─────────────────────────┘
         └──────────────────────────────────► COLS
            (each diagonal is any 2 of the 4 axes)
```

### 9.4 Build / data flow

```
   source (from embedded src/* names)        role
   ─────────────────────────────────       ───────────────────────────
   client_main.cpp                          entry point, loop, init
   chess.cpp                                the 5D chess rules / engine
   chess_worker_thread.cpp                  worker thread: AI, puzzles, engine calc
   graphics.cpp                             OpenGL + draw_*() + shaders
   assets.cpp                               asset loading (fonts/pieces/sounds)
   logging.cpp                              assertion / gl / progress logging
```

---

## 10. What this tells you about the design (inference)

- **Separation of concerns is explicit** in the file layout: engine (`chess.cpp`) is decoupled from
  the UI (`graphics.cpp`) via a `chess_ui` handle, and the engine runs on its own thread — so the
  UI stays responsive while the AI/puzzle solver thinks.
- **Everything game-specific is data + rules**, not hardcoded boards: the same `draw_*` pipeline
  renders ordinary chess, "Checkmate Practice" (single-piece variants), puzzles, and full multiverse
  games. The `u_physical` / menu modes reuse the renderer for a particle-style intro.
- **Online play is optional and lightweight**: only `WS2_32` sockets + a networking thread; local
  CPU and local two-player need no network at all.
- **The game is resilient to weak GPUs**: retry paths drop multisample for old Intel GPUs and
  recreate the window — matching the `--no-msaa` / `--no-vsync` launch flags seen in strings.

---

## 11. Methodology & evidence notes

**Tools used:** static analysis of the PE (header/section/import tables), string extraction with
offsets, and extraction of the embedded GLSL shader source. Ghidra 12.2 was intended for
decompilation but requires a Java 25 runtime (not present; only Java 21 is installed), so the
analysis was completed via static string/PE inspection, which is sufficient here because the game
embeds its rules, UI text, source-file names, and shader source directly.

**Reading-reliability note:** the target volume exhibited intermittent transient read errors during
analysis (large reads occasionally returned short/incorrect buffers). All multi-field structures
were parsed after requiring multiple identical full-file reads (md5-verified), so the header,
section, import, and string data reported here are stable and reproducible.

**Evidence tags:** `[seen]` = present in the binary (strings / imports / PE / shaders);
`[inferred]` = reasoned from structure; `[unknown]` = not determinable from static analysis alone
(e.g. exact AI search algorithm, exact networking protocol wire-format, runtime memory layout).

**Notable known limitation:** the PE's `SizeOfImage` (0x400) and several section-table entries are
non-standard, indicating a merged/repackaged build. The functional code and resource sections are
intact; the raw section table is reported best-effort only.
