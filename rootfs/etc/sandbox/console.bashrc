# sandbox 控制台 shell 配置（bash --rcfile 专用，不加载系统默认 bashrc）
export PS1='\[\e[36m\][sandbox]\[\e[0m\] \w \$ '
cd /home/container 2>/dev/null
alias ll='ls -la'
alias status='supervisorctl status'
alias proot='sandbox-proot'
