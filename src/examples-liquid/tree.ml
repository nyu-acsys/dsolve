qualif POS(x): 0 < x
qualif NEG(x): x < 0

type 'a tree = | Empty
               | Node of 'a tree * 'a * 'a tree

let empty = Empty
let _ = empty

let one_node = Node (Empty, 1, Empty)
let _ = one_node

let two_node = Node (one_node, 2, Empty)
let _ = two_node

let three_node = Node (Empty, -3, two_node)
let _ = three_node

let four_node = Node (one_node, 4, two_node)
let _ = four_node

let five_node = Node (empty, 5, four_node)
let _ = five_node