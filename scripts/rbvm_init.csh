if ( ${%GEM_HOME} > 0) setenv rbvm_sys_gem_home "$GEM_HOME"
if ( ${%GEM_PATH} > 0) setenv rbvm_sys_gem_path "$GEM_PATH"

alias rbvm 'source "<%rbvm_path%>/lib/rbvm.csh"'

rbvm --csh --quiet use default
