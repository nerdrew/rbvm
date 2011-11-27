# bash or zsh
if [[ -n "$BASH" || -n "$ZSH_NAME" ]]; then
  export rbvm_sys_gem_home="$GEM_HOME"
  export rbvm_sys_gem_path="$GEM_PATH"

  rbvm(){
    local rbvm_debug=''
    local rbvm_ruby="<%rbvm_ruby%>"
    local rbvm_irb="<%rbvm_irb%>"
    local rbvm_path="<%rbvm_path%>"
    local rbvm_rbvmrb="<%rbvm_rbvmrb%>"
    case "$1" in
      (reload)
        source "$rbvm_path"/lib/rbvm_init.sh
        return
        ;;
      (interactive | -i)
        rbvm_path="$rbvm_path" RUBYOPT= GEM_HOME= GEM_PATH= "$rbvm_ruby" --disable-gems "$rbvm_irb" -r "$rbvm_rbvmrb"
        return
        ;;
      (*)
        local rbvm_cmd="`rbvm_path="$rbvm_path" RUBYOPT= GEM_HOME= GEM_PATH= "$rbvm_ruby" --disable-gems "$rbvm_rbvmrb" $*`" 3>&1
        if [[ -n $rbvm_debug ]]; then echo rbvm_cmd: \'"${rbvm_cmd}"\'; echo; fi
        eval "$rbvm_cmd"
        ;;
    esac
  }

else
  echo "Unsupported Shell." 1>&2
fi

rbvm --quiet use default
