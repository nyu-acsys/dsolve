qual P(x): 0 < x;;
qual N(x): x < 0;;
qual NNEG(x): 0 <= x;;

? let f = fun n ->
  if n = 0 then
    1
  else
    n
in
  f 0;;
