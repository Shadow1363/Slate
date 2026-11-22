---
type: character
folder: characters
label: Character
icon: person.fill
fields:
  name: text
  aliases: list
  age: number
  role: {type: choice, options: [lead, supporting, antagonist]}
  alive: bool
  first appearance: link
  allies: links
  backstory: longtext
  portrait: image
  tags: list
layout:
  - type: header
    text: Story
    above: first appearance
  - type: columns
    keys: [age, role]
---
## Want

## Need

## Secret

## Ghost
