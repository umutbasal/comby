open Angstrom
open Core_kernel

open Types

let default_syntax =
  Syntax.{ user_defined_delimiters = Languages.C.Syntax.user_defined_delimiters
         ; escapable_string_literals = Languages.C.Syntax.escapable_string_literals
         ; raw_string_literals = Languages.C.Syntax.raw_string_literals
         ; comments = Languages.C.Syntax.comments
         }

class syntax
    Syntax.{ user_defined_delimiters
           ; escapable_string_literals
           ; raw_string_literals
           ; comments
           } = object(_)
  method user_defined_delimiters = user_defined_delimiters
  method escapable_string_literals = escapable_string_literals
  method raw_string_literals = raw_string_literals
  method comments = comments
end

module Printer = struct
  class printer = object(_)
    inherit syntax default_syntax
    inherit [string] Template_visitor.visitor

    method !enter_other other =
      [Format.sprintf "Other: %s@." other]

    method !enter_spaces spaces =
      [Format.sprintf "Spaces: %s@." spaces]

    method !enter_hole { identifier; _ } =
      [Format.sprintf "Hole: :[%s]@." identifier]

    method !enter_delimiter left right body =
      [Format.sprintf "Delim_open: %s@.\t%sDelim_close: %s@." left (String.concat ~sep:"\t" body) right]

    method !enter_toplevel parsed =
      [Format.sprintf "Toplevel: %s@." (String.concat ~sep:"," parsed)]
  end

  let run match_template =
    Template_visitor.fold (new printer) match_template
end

let is_whitespace = function
  | ' ' | '\t' | '\r' | '\n' -> true
  | _ -> false

(* FIXME use skip_while once everything works, we don't need the string *)
let spaces1 =
  satisfy is_whitespace >>= fun c ->
  take_while is_whitespace >>= fun s ->
  return (Format.sprintf "%c%s" c s)

let alphanum =
  satisfy (function
      | 'a' .. 'z'
      | 'A' .. 'Z'
      | '0' .. '9' -> true
      | _ -> false)

module Matcher = struct

  type omega_match_production =
    { offset : int
    ; identifier : string
    ; text : string
    }
  [@@deriving yojson]

  (* A simple production type that only saves matches *)
  type production =
    | Parsed
    | Match of omega_match_production
    | Deferred of hole

  let make_unit p =
    p >>= fun _ -> return Parsed

  class generator = object(self)
    inherit syntax default_syntax
    inherit [production Angstrom.t] Template_visitor.visitor

    method !enter_other other =
      [make_unit @@ string other]

    (* Includes swallowing comments for now. See template_visitor. *)
    method !enter_spaces _ =
      [ make_unit @@ spaces1 ]

    (* Apply rules here *)
    method enter_match (matched : omega_match_production) : production =
      Match matched

    (* Wrap the hole so we can find it in enter_delimiter *)
    method !enter_hole ({ sort; identifier; _ } as hole) =
      match sort with
      | Everything -> [return (Deferred hole)]
      | Alphanum ->
        let result =
          pos >>= fun pos_before ->
          many1 ((alphanum <|> char '_') >>| String.of_char)
          >>= fun matched ->
          let text = String.concat matched in
          return (self#enter_match ({ offset = pos_before; identifier; text }))
        in
        [ result ]

      | _ -> failwith "TODO"

    method !enter_delimiter left right body =
      (* call the hole converter here... *)
      [make_unit @@ string left] @ body @ [make_unit @@ string right]

    (* method !enter_toplevel. Here, we would put the matcher around comments n such *)
  end

  let run match_template =
    Template_visitor.fold (new generator) match_template

  (* sequences a list of parsers to one parser, throwing away all results except the last. *)
  let sequence_chain (p_list : production Angstrom.t list) : production Angstrom.t =
    List.fold p_list ~init:(return Parsed) ~f:( *>)

  (* sequences a list of parsers and accumulates their productions in a list *)
  let map_chain (p_list : production Angstrom.t list) : production list Angstrom.t =
    List.fold p_list ~init:(return []) ~f:(fun acc parser ->
        acc >>= fun acc ->
        parser >>= fun result ->
        return (result::acc))
end

let debug = false

module Engine = struct
  let run source p =
    let state = Buffered.parse p in
    let state = Buffered.feed state (`String source) in
    let state = Buffered.feed state `Eof in
    match state with
    | Buffered.Done ({ len; off; _ }, result) ->
      if len <> 0 then
        (if debug then
           Format.eprintf "Input left over in parse where not expected: off(%d) len(%d)" off len;
         Or_error.error_string "Does not match tempalte")
      else
        Ok result
    | _ -> Or_error.error_string "No matches"
end

let fold source p_list ~f ~init =
  let accumulator =
    List.fold p_list ~init:(return init) ~f:(fun acc parser ->
        acc >>= fun acc ->
        parser >>= fun parsed ->
        return (f acc parsed))
  in
  Engine.run source accumulator

(* sequence_chain converts 'everything' holes in the level to matches *)
let convert_everything_holes (p_list : Matcher.production Angstrom.t list)
  : Matcher.production Angstrom.t list =
  let i = ref 0 in
  let result =
    List.fold_right p_list ~init:[] ~f:(fun _p acc ->
        (* TODO *)
        acc
      )
  in
  i := !i + 1;
  result