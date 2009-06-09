let show x = ()

let abs x = 
  if x > 0 then x else (0-x)

let div a b = 
  assert (b != 0);
  a/b

let trunc i n = 
  let i' = abs i in
  let n' = abs n in
  if i' <= n' then i else 
    let _ = show i' in
    n' * (div i i')
