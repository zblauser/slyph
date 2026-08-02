Output assets/slyph.gif

Set Shell "bash"
Set FontSize 16
Set Width 1100
Set Height 700
Set Padding 20
Set Theme "Dracula"
Set Framerate 20
Set TypingSpeed 90ms

Hide
Type "zig build" Enter
Sleep 5s
Type 'export PATH="$PWD/zig-out/bin:$PATH"' Enter
Sleep 500ms
Type "clear" Enter
Show

Type "slyph news.ycombinator.com"
Sleep 700ms
Enter
Sleep 4s

Type "j"
Sleep 900ms
Type "j"
Sleep 900ms
Type "j"
Sleep 1500ms

Ctrl+L
Sleep 900ms
Type "news.ycombinator.com/item?id=49117099"
Sleep 600ms
Enter
Sleep 4500ms

Type "j"
Sleep 900ms
Type "j"
Sleep 1800ms

Type "H"
Sleep 2500ms

Type "q"
Sleep 1200ms
