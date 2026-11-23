---
type: vessel
folder: vessels
label: Vessel
icon: sailboat.fill
nameField: name
fields:
  name: text
  aliases: list
  kind: {type: choice, label: Kind, options: [trawler, salvage tug, rowboat, ferry]}
  home port: link
  captain: link
  crew: links
  seaworthy: bool
  length: {type: number, label: Length (m)}
  launched: date
  history: longtext
  picture: image
  tags: list
layout:
  - type: image
    key: picture
  - type: columns
    keys: [kind, length]
  - type: header
    text: People
    above: captain
---
## Description

## Voyages
