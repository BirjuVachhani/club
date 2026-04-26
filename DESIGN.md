# DESIGN.md — club Brand & Design System

## Brand Identity

**club** is a self-hosted, private Dart package repository. The brand is **bold, utilitarian, and developer-focused** — a tool that gets out of the way while being unmistakably distinctive.

**Tone:** Industrial warmth. Confident, functional, no-nonsense.
**Differentiation:** The Radiant Orange accent on near-black/near-white surfaces. Instantly recognizable.

---

## Color Palette

### Brand Colors

| Name               | Hex       | Usage                                      |
| ------------------ | --------- | ------------------------------------------ |
| Radiant Orange  | `#FF4F18` | Primary accent, CTAs, links, active states  |
| Coal Black         | `#050505` | Dark mode background, hero sections         |
| Pure White         | `#FFFFFF` | Light mode background                       |
| Pure White         | `#FFFFFF` | Light mode cards, surfaces                   |
| Silver Mist        | `#E4E4E4` | Light mode borders, dividers                 |

### Light Mode

| Token              | Value     | Purpose                     |
| ------------------ | --------- | --------------------------- |
| `--background`     | `#FFFFFF` | Page background (Pure White)|
| `--foreground`     | `#141517` | Primary text (Coal Black)   |
| `--card`           | `#FFFFFF` | Card/surface background     |
| `--primary`        | `#FF4F18` | Accent (Radiant Orange)  |
| `--primary-foreground` | `#FFFFFF` | Text on primary          |
| `--muted`          | `#EAECF0` | Subtle backgrounds          |
| `--muted-foreground` | `#64748B` | Secondary text            |
| `--border`         | `#E0E2E7` | Borders, dividers           |
| `--accent`         | `#FFF0EB` | Orange-tinted hover/active  |

### Dark Mode

| Token              | Value     | Purpose                     |
| ------------------ | --------- | --------------------------- |
| `--background`     | `#050505` | Page background (Coal Black)|
| `--foreground`     | `#EDEDED` | Primary text                |
| `--card`           | `#111111` | Card/surface background     |
| `--primary`        | `#FF4F18` | Accent (same orange)        |
| `--primary-foreground` | `#FFFFFF` | Text on primary          |
| `--muted`          | `#161616` | Subtle backgrounds          |
| `--muted-foreground` | `#9A9AA1` | Secondary text            |
| `--border`         | `#252525` | Borders, dividers           |
| `--accent`         | `#1C1410` | Orange-tinted hover/active  |

### Semantic Colors

| Name        | Light       | Dark        | Usage                    |
| ----------- | ----------- | ----------- | ------------------------ |
| Link        | `#FF4F18`   | `#FF6633`   | Clickable text, names    |
| Link Hover  | `#CC3600`   | `#FF8855`   | Hovered links            |
| Tag BG      | `#FFF0EB`   | `#1C1410`   | SDK/platform tag fills   |
| Tag Text    | `#CC3600`   | `#FF8855`   | Tag label color          |
| Success     | `#16A34A`   | `#22C55E`   | Success states           |
| Error       | `#DC2626`   | `#EF4444`   | Error/destructive states |

### Orange Gradient (Brand Mark)

```
linear-gradient(180deg, #FF4F18 0%, #050505 100%)
```

Used for hero backgrounds and brand moments. Never for text.

---

## Typography

### Font Stack

| Role        | Family                            | Weight    | Usage                 |
| ----------- | --------------------------------- | --------- | --------------------- |
| Brand       | Bitcount Grid Double (variable)   | 500       | Logo "CLUB" only     |
| Body        | Inter Variable                    | 400, 500  | All body text         |
| Headings    | Inter Variable                    | 600, 700  | Section headings      |
| Code        | Fira Code                         | 400, 500  | Code blocks, versions |

### Type Scale

| Element      | Size     | Weight | Line Height | Letter Spacing |
| ------------ | -------- | ------ | ----------- | -------------- |
| Hero title   | 56px     | 500    | 1.0         | 0.02em         |
| Page heading | 26px     | 700    | 1.2         | -0.01em        |
| Section head | 20px     | 700    | 1.3         | 0              |
| Card title   | 16px     | 600    | 1.3         | 0              |
| Body         | 14px     | 400    | 1.6         | 0              |
| Small/meta   | 12-13px  | 400-500| 1.4         | 0              |
| Tag labels   | 10-11px  | 600-700| 1.0         | 0.03-0.05em    |
| Code         | 0.9rem   | 400    | 1.5         | 0              |

### Logo

The "CLUB" wordmark uses **Bitcount Grid Double** at weight 500, uppercase, `tracking-tight`. It appears alongside an orange rounded-square icon containing a lowercase "m" in white.

---

## Spacing & Layout

### Spacing Scale

```
4px, 6px, 8px, 10px, 12px, 16px, 20px, 24px, 32px, 40px, 48px, 64px, 80px
```

### Container

- Max width: `72rem` (1152px)
- Horizontal padding: `16px` mobile, `24px` desktop

### Grid

- Package cards: `repeat(auto-fill, minmax(260px, 1fr))`, 12px gap
- Package detail: `minmax(0, 1fr) 280px` sidebar, 32px gap
- Package list: sidebar `180px` + content, 32px gap

---

## Borders & Corners

| Element           | Radius | Border                           |
| ----------------- | ------ | -------------------------------- |
| Cards             | 10px   | 1px solid `var(--border)`        |
| Sidebar panel     | 12px   | 1px solid `var(--border)`        |
| Buttons (default) | 8px    | 1px solid `var(--border)`        |
| Inputs            | 8px    | 1.5px solid `var(--border)`      |
| Tabs container    | 10px   | none (filled background)         |
| Tab items         | 7px    | none                             |
| Logo icon         | 8px    | none                             |
| Tags/badges       | 3-4px  | none                             |
| Pill (search)     | 999px  | 1.5px solid `var(--border)`      |

---

## Components

### Buttons

**Primary** — Orange fill, white text:
```css
background: var(--primary);
color: white;
border: none;
border-radius: 8px;
font-weight: 600;
padding: 8px 16px;
```

**Secondary/Outline** — Transparent, border, text color:
```css
background: transparent;
color: var(--foreground);
border: 1px solid var(--border);
border-radius: 8px;
font-weight: 500;
padding: 8px 16px;
```

**Ghost** — No border, subtle hover:
```css
background: transparent;
color: var(--foreground);
border: none;
border-radius: 8px;
padding: 8px 16px;
```
Hover: `background: var(--accent)`

### Search Bar (Outline Style)

Single container with border, icon + input + separated button:
```css
border: 1.5px solid var(--border);
border-radius: 8px;
background: var(--background);
height: 40px;
```
Button separated by `border-left: 1.5px solid var(--border)`, transparent background, hover fills with `var(--accent)`.

### Tags / Badges

**SDK/Platform compat tags** — Two-part badge:
- Label (SDK, PLATFORM): `var(--pub-link-text-color)` background, white text
- Values (DART, FLUTTER, ANDROID...): `var(--pub-tag-background)` fill, `var(--pub-tag-text-color)` text

**General tags**: `10-11px`, uppercase, `font-weight: 600`, `letter-spacing: 0.03em`

### Cards (Home Page)

```css
min-height: 150px;
padding: 16px 18px;
border: 1px solid var(--border);
border-radius: 10px;
background: var(--card);
```
Hover: `border-color: var(--pub-link-text-color)`, subtle shadow.

### Package List Items

Flat list with `border-bottom` dividers. No card wrapping. Hover adds subtle background fill and border-radius.

### Sidebar (Package Detail)

```css
background: var(--muted);
border: 1px solid var(--border);
border-radius: 12px;
padding: 20px;
```

### Tabs (Pill Style)

Container has `var(--pub-tag-background)` background, 4px padding, 10px radius. Active tab gets `var(--background)` fill with subtle shadow.

---

## Hero Section

The home page hero uses the dark brand background:

```css
background: #050505; /* Coal Black - same in both themes */
color: white;
```

Search input inside hero: semi-transparent white background (`rgba(255,255,255,0.12)`), white text, rounded corners. Focus state brightens background.

---

## Header

- Height: 56px (`h-14`)
- Background: `var(--card)` with bottom border
- Logo: Orange square (8px radius) + Bitcount Grid Double wordmark
- Search: Outline style, fills available width
- Actions: ghost icon buttons, profile avatar without border

---

## Dark Mode Principles

1. **Background**: True black (`#050505`) — not gray, not blue-tinted
2. **Surfaces**: `#111111` for cards — minimal lift from background
3. **Orange stays orange**: `#FF4F18` primary is the same, links lighten to `#FF6633`
4. **Borders**: `#252525` — barely visible separation
5. **Tags**: Warm-tinted dark background (`#1C1410`) with `#FF8855` text
6. **No glow effects**: Keep it flat and grounded

---

## Code Blocks

### Light Mode (GitHub-inspired)

```css
background: #EEF0F4;
border: 1px solid #D8DCE3;
color: #24292E;
```

### Dark Mode (GitHub Dark-inspired)

```css
background: #0D1117;
border: 1px solid #30363D;
color: #E6EDF3;
```

Copy button appears on hover, positioned top-right.

---

## Motion & Transitions

- **Duration**: 150ms for hover states, 200ms for page transitions
- **Easing**: `ease` for simple transitions
- **Properties**: `color`, `background`, `border-color`, `box-shadow`, `opacity`
- **No bounce/elastic**: Keep motion grounded and snappy
- No animated gradients or glow pulses

---

## Iconography

- **Style**: Lucide icons (outline, 2px stroke)
- **Sizes**: 14-18px depending on context
- **Color**: Inherits from parent text color
- No filled icons. No emoji as UI elements.
