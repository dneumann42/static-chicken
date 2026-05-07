(declare (uses raylib))

(import (chicken base))

(init-window 800 600 "static-chicken — raylib 6.0 software renderer")
(set-target-fps 60)

(let loop ()
  (unless (window-should-close?)
    (begin-drawing)
    (clear-background  30  30  40 255)
    (draw-rectangle 200 150 400 300 240 80 60 255)
    (end-drawing)
    (loop)))

(close-window)
