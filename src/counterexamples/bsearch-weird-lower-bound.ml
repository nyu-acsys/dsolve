pred U(x): x < alen;;
pred L(x): 0 <= x;;

? let bsearch = fun k -> fun a ->
  let look = fun l -> fun h ->
    if l <= h then
      let m = l + (h - l) in
	if Ref(a, m) = k then
	  Some(m, x)
	else
	  if Ref(a, m) < k then
	    look l (m - 1)
	  else
	    look (m + 1) h
    else
      None
  in
    look -1 alen
in
  bsearch c r;;
