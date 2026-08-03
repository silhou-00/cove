# Frontend

## Responsiveness

Scale components to the **actual rendered viewport width at 100% zoom** — never assume a scaled OS display.

| Display class | Range | Strategy |
|---|---|---|
| Mobile | < 768px | Fluid full-width, stack vertically |
| Tablet | 768–1279px | Two-column grids, generous touch targets |
| Laptop / desktop | 1280–1919px | Fixed max-width containers, comfortable padding |
| Full HD | 1920px | Wider containers, slightly larger whitespace/type |
| QHD / 2K | 2560px | Expand max-width; scale spacing and type; no lost-in-void content |
| 4K+ | 3840px+ | Large centered containers with generous margins; never full-width stretch |

- Use `clamp()` for fluid type/spacing (a CSS function that sets a value with a floor and ceiling so it scales smoothly between screen sizes). Never raw `vw` alone for font sizes.
- Wide monitors (1920px+): constrain content width, don't stretch it.
- Touch targets at least 44×44px on mobile/tablet.
- Verify layout at every breakpoint before finishing.

## Layout

- Flexbox for component flow and alignment; CSS Grid for two-dimensional layouts needing explicit rows and columns.
- Custom scrollbar styled to the design system — never the browser default.
- Keep the DOM hierarchy flat; avoid deeply nested layout wrappers.

## Design & theming

- All colors, fonts, weights, and base sizes live in a **token layer** (`@theme` / CSS variables). Never hardcode a color outside it. If the project has an existing `@theme`, use it.
- `rem` for all sizing and type; never `px` for fonts. Utility classes are fine where they express intent cleanly.
- Icons from one consistent library (e.g. lucide-react). Never emojis as UI elements.
- One cohesive visual identity per project, executed consistently. Distinctive type pairing (display + body); avoid generic defaults (Inter, Roboto, Arial, system-ui). No purple-gradient-on-white, no predictable card-grid "AI slop" layouts.
- Motion with purpose: orchestrated page-load reveals beat scattered micro-interactions. CSS transitions for simple states; a motion library only for complex sequences.

## State & reactivity (framework-agnostic)

- **Reactive state** (`useState` / `ref` / signal): only for data that must trigger a UI update. Never store derived values — compute them during render. Keep state as close to its use as possible.
- **Effects** (`useEffect` / `watchEffect`): strictly for syncing with external systems (API calls, subscriptions, DOM APIs, global listeners). Always clean up. Never chain state updates or transform data in effects — transform during render instead.
- **Memoized functions** (`useCallback`): only when passed to optimized children or needed as a stable dependency. Don't wrap everything.
- **Memoized values** (`useMemo` / `computed`): expensive calculations and referential stability for props. Not for simple expressions.
- **Refs** (`useRef`): direct DOM access, and mutable values that persist across renders without triggering them (timer IDs, flags, previous values). Never as a reactive data source driving UI.
- Data-driven UI updates in real time when the underlying data changes.
