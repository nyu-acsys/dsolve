qualifier NNEG(x) = 0 <= x;;

let abs x = if x < 0 then (0 - x) else x in
let s = abs 1 in
let t = abs (-1) in
  s;;
