if exists('g:loaded_vimbird')
  finish
endif
let g:loaded_vimbird = 1

command! Vimbird call vimbird#Open()
command! VimbirdClose call vimbird#Close()
command! VimbirdToggle call vimbird#Toggle()
command! VimbirdRefresh call vimbird#Refresh()
command! VimbirdOverview call vimbird#Overview()
command! VimbirdStats call vimbird#Stats()

if empty(maparg('<LeftMouse>', 'n')) && empty(maparg('<LeftDrag>', 'n')) && empty(maparg('<LeftRelease>', 'n'))
  nnoremap <expr> <LeftMouse> vimbird#MouseKey('click')
  nnoremap <expr> <LeftDrag> vimbird#MouseKey('drag')
  nnoremap <expr> <LeftRelease> vimbird#MouseKey('release')
endif
