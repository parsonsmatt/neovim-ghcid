"
" neovim-ghcid
"
" Author:       Alexis Sellier <http://cloudhead.io>
" Version:      0.1

if exists("g:loaded_ghcid") || &cp || !has('nvim')
  finish
endif
let g:loaded_ghcid = 1

if !exists("g:ghcid_lines")
    let g:ghcid_lines = 10
endif

if !exists("g:ghcid_keep_open")
    let g:ghcid_keep_open = 0
endif

if !exists("g:ghcid_command")
    let g:ghcid_command = "ghcid"
endif

let s:ghcid_base_sign_id = 100
let s:ghcid_sign_id = s:ghcid_base_sign_id
let s:ghcid_dummy_sign_id = 99
let s:ghcid_job_id = 0
let s:ghcid_error_header = {}
let s:ghcid_win_id = -1
let s:ghcid_buf_id = -1

command! Ghcid     call s:ghcid()
command! GhcidKill call s:ghcid_kill()

sign define ghcid-error text=× texthl=ErrorSign
sign define ghcid-dummy

function! s:ghcid_init()
  exe 'sign' 'place'  s:ghcid_dummy_sign_id  'line=9999' 'name=ghcid-dummy' 'buffer=' . bufnr('%')
endfunction

function! s:ghcid_winnr()
  return win_id2win(s:ghcid_win_id)
endfunction

function! s:ghcid_bufnr()
  return bufnr(s:ghcid_buf_id)
endfunction

function! s:ghcid_gotowin()
  call win_gotoid(s:ghcid_win_id)
endfunction

function! s:ghcid_update_status(nerrs)
  if s:ghcid_winnr() <= 0
    return
  endif

  call s:ghcid_gotowin()
  let b:ghcid_status = 'Ghcid: All good'
  if a:nerrs > 0
    let b:ghcid_status = 'Ghcid: ' . string(a:nerrs) . ' error(s)'
  endif
  setlocal statusline=%{b:ghcid_status}
  wincmd p
endfunction

function! s:ghcid_closewin()
  if !g:ghcid_keep_open
    call s:ghcid_gotowin()
    quit
  endif
endfunction

autocmd BufWritePost,FileChangedShellPost *.hs call s:ghcid_clear_signs()
autocmd TextChanged                       *.hs call s:ghcid_clear_signs()
autocmd BufEnter                          *.hs call s:ghcid_init()

let s:ghcid_error_header_regexp=
  \   '^\s*\([^\t\r\n:]\+\):\(\d\+\):\(\d\+\): error:'

let s:ghcid_error_text_regexp=
  \   '\s\+\([^\t\r\n]\+\)'

function! s:ghcid_parse_error_text(str) abort
  let result = matchlist(a:str, s:ghcid_error_text_regexp)
  if !len(result)
    return
  endif
  return result[1]
endfunction

function! s:ghcid_parse_error_header(str) abort
  let result = matchlist(a:str, s:ghcid_error_header_regexp)
  if !len(result)
    return {}
  endif

  let file = result[1]
  let lnum = result[2]
  let col  = result[3]

  " Find buffer after making file path relative to cd.
  " If the buffer isn't valid, vim will use the 'filename' entry.
  let efile = fnamemodify(expand(file), ':.')

  " Not a valid filename.
  if empty(efile)
    return {}
  endif

  let entry = { 'type': 'E',
              \ 'filename': efile,
              \ 'lnum': str2nr(lnum),
              \ 'col': str2nr(col) }

  let buf = bufnr(efile)
  if buf > 0
    let entry.bufnr = buf
  endif

  return entry
endfunction

function! s:ghcid_add_to_qflist(e)
  let qflist = getqflist()
  for i in qflist
    if i.lnum == a:e.lnum && i.bufnr == a:e.bufnr
      return
    endif
  endfor
  " Append to existing list.
  call setqflist([a:e], 'a')
endfunction

function! s:ghcid_update(ghcid, data) abort
  let data = copy(a:data)

  " If we see 'All good', then there are no errors and we
  " can safely close the ghcid window and reset the qflist.
  if !empty(matchstr(join(data), "All good"))
    if s:ghcid_winnr()
      call s:ghcid_closewin()
    endif
    echo "Ghcid: OK"
    call setqflist([])
    return
  endif

  " Try to parse an error header string. If it succeeds, set the top-level
  " variable to the result.
  let error_header = s:ghcid_error_header
  if empty(error_header)
    while !empty(data)
      let error_header = s:ghcid_parse_error_header(data[0])
      let data = data[1:]

      if !empty(error_header)
        let s:ghcid_error_header = error_header
        break
      endif
    endwhile

    " If we haven't found a header and there is nothing left to parse,
    " there's nothing left to do.
    if empty(error_header) || empty(data)
      return
    endif
  endif

  " Try to parse the error text. If we got to this point, we have
  " an error header and some data left to parse.
  let error_text           = s:ghcid_parse_error_text(join(data))
  let error                = copy(error_header)
  let error.text           = error_text
  let error.valid          = 1
  let s:ghcid_error_header = {}

  call s:ghcid_add_to_qflist(error)
  call s:ghcid_update_status(len(getqflist()))

  " Since we got here, we must have a valid error.
  " Open the ghcid window.
  if !s:ghcid_winnr()
    bot new | exe 'buffer' s:ghcid_bufnr()
    let s:ghcid_win_id = win_getid()
    execute 'resize' g:ghcid_lines
    normal! G
    wincmd p
  endif

  silent exe "sign"
    \ "place"
    \ s:ghcid_sign_id
    \ "line=" . error.lnum
    \ "name=ghcid-error"
    \ "file=" . error.filename

  let s:ghcid_sign_id += 1
endfunction

function! s:ghcid_clear_signs() abort
  for i in range(s:ghcid_base_sign_id, s:ghcid_sign_id)
    silent exe 'sign' 'unplace' i
  endfor
  let s:ghcid_sign_id = s:ghcid_base_sign_id

  " Clear the quickfix list.
  call setqflist([])
endfunction

function! s:ghcid() abort
  let opts = {}
  let s:ghcid_killcmd = 0

  if s:ghcid_winnr() > 0
    echo "Ghcid: Already running"
    return
  endif

  function! opts.on_exit(id, code)
    if a:code != 0 && !s:ghcid_killcmd
      echoerr "Ghcid: Exited with status " . a:code
    endif
  endfunction

  function! opts.on_stdout(id, data, event) abort
    call s:ghcid_update(self, a:data)
  endfunction

  exe 'below' g:ghcid_lines . 'new'
  set nobuflisted

  if s:ghcid_bufnr() > 0
    exe 'buffer' s:ghcid_bufnr()
  else
    call termopen(g:ghcid_command, opts)
    let s:ghcid_job_id = b:terminal_job_id
  endif

  let s:ghcid_win_id = win_getid()
  let s:ghcid_buf_id = bufnr('%')
  file ghcid
  wincmd p
endfunction

function! s:ghcid_kill() abort
  if s:ghcid_bufnr() > 0
    let s:ghcid_killcmd = 1
    silent exe 'bwipeout!' s:ghcid_bufnr()
    let s:ghcid_buf_id = -1
    let s:ghcid_win_id = -1
    echo "Ghcid: Killed"
  else
    echo "Ghcid: Not running"
  endif
endfunction
