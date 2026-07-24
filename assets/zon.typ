#set document(
  author: "Jassiel Ovando",
  description: "Zig logos",
)

#set page(
  height: 200pt,
  width: 200pt,
  margin: 0pt,
  fill: none,
)

#let zig-yellow = rgb("#F7A41D")

#set align(center + horizon)
#set par(justify: true)

#set text(
  font: "Monaspace Xenon",
  weight: 600,
  baseline: -10pt,
  size: 150pt,
)

// This would be ideal for file editors, as a small icon.
#grid(
  columns: (1fr, 1fr, 1fr),
  align: right,
  column-gutter: (-30pt, 20pt),
  text(".", baseline: -2.5pt), text("{", fill: zig-yellow), text("}", fill: zig-yellow),
)

#pagebreak()
// This could be an alternative to the normal icon, fitting for a larger display or desktop icons, as the ellipsis adds more noise in smaller sizes.
#grid(
  columns: (0.9fr, 1fr, 1fr, 1fr),
  align: right,
  column-gutter: (-40pt, -20pt, -20pt),
  text(".", baseline: -7.5pt), text("{", fill: zig-yellow), text(sym.dots, baseline: 0pt), text("}", fill: zig-yellow),
)

#pagebreak()

// Ideally, this would be either for also desktop icons, or for the build script (build.zig) or manifest file (build.zig.zon), the mark in the middle is the battery-Z icon if Zig. I'd guess it fits better for the manifest rather than build script, as that's a ZON file, whereas the Ziggy one is a normal Zig file.
#let struct-dot = text(".", baseline: -5pt, size: 125pt, weight: 400)
#place(struct-dot, dx: -15pt, dy: 50pt)
#grid(
  columns: (1fr, 1fr, 1fr),
  align: (left, center, right),
  column-gutter: (-20pt, -20pt),
  text("{", fill: zig-yellow), image("svg/zig-mark.svg"), text("}", fill: zig-yellow),
)

#pagebreak()
#place(text(".", baseline: -5pt, size: 125pt, weight: 600, fill: zig-yellow), dx: -22.5pt, dy: 57.5pt)
#set text(weight: 500)
#grid(
  columns: (1fr, 1fr, 1fr),
  align: (left, center, right),
  column-gutter: (-20pt, -20pt),
  text("{", fill: zig-yellow), rotate(image("svg/zig-mark-z.svg", width: 165%), -7.5deg), text("}", fill: zig-yellow),
)

#pagebreak()
#set text(font: "Source Sans 3", weight: 900)
// #place(text(".", baseline: 0pt, fill: zig-yellow), dx: 10pt, dy: 50pt)
#grid(
  columns: (1fr, 1fr, 1fr),
  align: (left, center, right),
  column-gutter: (-200pt, -200pt),
  text("{", fill: zig-yellow), image("svg/zig-mark-z.svg", width: 100%), text("}", fill: zig-yellow),
)

#pagebreak()
#image("svg/zig-mark-z.svg")
