#!/bin/csh

set rbvm_debug=
set rbvm_ruby="<%rbvm_ruby%>" 
set rbvm_irb="<%rbvm_irb%>" 
set rbvm_path="<%rbvm_path%>" 
set rbvm_rbvmrb="<%rbvm_rbvmrb%>" 

switch("$1") 
case "reload": 
  source "$rbvm_path"/lib/rbvm_init.csh 
  breaksw 
case "interactive": 
case "-i": 
  env rbvm_path="$rbvm_path" RUBYOPT= GEM_HOME= GEM_PATH= "$rbvm_irb" -r "$rbvm_rbvmrb"  
  breaksw 
default: 
  set rbvm_cmd="`env rbvm_path="$rbvm_path" RUBYOPT= GEM_HOME= GEM_PATH= "$rbvm_ruby" "$rbvm_rbvmrb" --csh $*`"
  if (${%rbvm_debug} > 0) echo rbvm_cmd: $rbvm_cmd
  eval "$rbvm_cmd"
endsw 

unset rbvm_debug
unset rbvm_ruby
unset rbvm_irb
unset rbvm_path
unset rbvm_rbvmrb
unset rbvm_cmd
