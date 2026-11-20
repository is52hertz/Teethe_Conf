#!/bin/zsh
emulate -LR zsh
setopt errexit nounset extendedglob

die() {
  print -ru2 -- "$*"
  exit 1
}

cd -- "${0:A:h}"
print -ru2 -- '输入要直连的域名，或粘贴完整规则（如 DOMAIN-SUFFIX,example.org,PROXY）'
IFS= read -r input || die '没有读到规则。'
input=${${input##[[:blank:]]#}%%[[:blank:]]#}
domain_pattern='^(\*\.)?([[:alnum:]]([[:alnum:]-]*[[:alnum:]])?\.)+[[:alnum:]]([[:alnum:]-]*[[:alnum:]])?$'
if [[ $input =~ $domain_pattern ]]; then
  rule="DOMAIN-SUFFIX,${input:l},DIRECT"
else
  input=${input//[[:blank:]]#,[[:blank:]]#/,}
  rule_pattern='^[a-zA-Z][a-zA-Z0-9-]*,[^,[:cntrl:]]+,[^,[:cntrl:]]+(,[^,[:cntrl:]]+)*$'
  [[ $input =~ $rule_pattern ]] || die '请输入域名或「类型,匹配值,策略」格式的规则。'
  kind=${input%%,*}
  rule="${kind:u},${input#*,}"
fi
# 显式保留 *.example.org 只匹配子域名的范围。
if [[ $rule == DOMAIN-SUFFIX,\*.* ]]; then
  rule="DOMAIN-WILDCARD,${rule#*,}"
fi
selector="${rule%%,*},${${rule#*,}%%,*}"
fields=("${(@s:,:)rule}")
case ${fields[1]} in
  AND|OR|NOT) heading='## - 自定义逻辑规则 - ##' ;;
  *) heading="## - 自定义分流 · ${fields[3]} - ##" ;;
esac

configs=(sr_cnip_ex.conf sr_cnip_ad_ex.conf)
[[ $(git branch --show-current) == main ]] || die '订阅从 main 更新，请在 main 分支运行。'

# 锁住整个同步过程，包括拉取、修改、提交和推送。
zmodload zsh/system
lock_file=$(git rev-parse --git-path add-rule.lock)
: >> "$lock_file"
zsystem flock -t 10 -f lock_fd "$lock_file" || die '另一份脚本正在更新配置，请稍后再试。'
if ! git diff --quiet -- "${configs[@]}" || ! git diff --cached --quiet -- "${configs[@]}"; then
  die '订阅配置有待提交的编辑，请先处理这些编辑，再运行脚本。'
fi
if git fetch --quiet --no-recurse-submodules origin main; then
  git merge --quiet --ff-only FETCH_HEAD || die '无法快进同步 origin/main，请处理上面的 Git 提示后重试。'
else
  print -ru2 -- '未能读取远端，继续处理本地规则，随后会尝试推送。'
fi
stage=$(mktemp -d .add-rule.XXXXXXXX)
typeset -a changed rollback
cleanup() {
  local file
  for file in "${rollback[@]}"; do
    mv -f -- "$stage/$file.orig" "$file" || {
      print -ru2 -- "恢复失败，原件保存在 ${stage:A}。"
      return 1
    }
  done
  rm -rf -- "$stage"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

prepare() {
  local file=$1 content line section='' last_section='' cr=''
  local -a lines additions
  local -i i in_rules=0 after=0
  # 保留原文件末尾的换行状态。
  content=$(cat -- "$file" && print -rn -- .)
  lines=("${(@f)${content%.}}")
  for (( i=1; i <= $#lines; ++i )); do
    line=${${lines[i]##[[:blank:]]#}%%[[:space:]]#}
    case $line in
      '[Rule]') in_rules=1; after=$i; continue ;;
      \[*\]) (( in_rules )) && break; continue ;;
      '## '*) section=$line; continue ;;
      ''|'#'*|';'*) continue ;;
    esac
    (( in_rules )) || continue
    line=${line//[[:blank:]]#,[[:blank:]]#/,}
    [[ $line == "$rule" ]] && return 0
    [[ $line != "$selector,"* ]] || die "$file 已有不同设置：$line"
    [[ $line != (FINAL|MATCH),* ]] || break
    after=$i
    last_section=$section
  done
  (( after )) || die "$file 缺少 [Rule] 段。"

  [[ ${lines[after]} == *$'\r' ]] && cr=$'\r'
  # 继续追加以保持规则优先级，同时避免把新规则挂在上一个服务名下。
  [[ $last_section == "$heading" ]] || additions+=("$cr" "$heading$cr")
  lines[after,after]=("${lines[after]}" "${additions[@]}" "$rule$cr")
  if [[ ${lines[1]} == '# Shadowrocket:'* ]]; then
    lines[1]="$timestamp_header$cr"
  else
    lines=("$timestamp_header$cr" "${lines[@]}")
  fi
  cp -p -- "$file" "$stage/$file.orig"
  cp -p -- "$file" "$stage/$file"
  print -rn -- "${(F)lines}" > "$stage/$file"
  changed+=("$file")
}

timestamp_header=$(TZ=Asia/Singapore date '+# Shadowrocket: %Y-%m-%d %H:%M:%S')
for file in "${configs[@]}"; do
  prepare "$file"
done
for file in "${changed[@]}"; do
  rollback+=("$file")
  mv -f -- "$stage/$file" "$file"
done
if (( $#changed )); then
  git commit --only -m "添加分流规则 $rule" -- "${changed[@]}"
  rollback=()
else
  print -r -- "两份配置均已有此规则：$rule"
fi

# 上次推送失败时，重新输入同一条规则也能发布已有的本地提交。
git push origin HEAD:refs/heads/main || die '推送失败，本地提交已保留。处理上面的 Git 错误后，重新输入同一条规则即可重试。'
print -r -- "已同步到 origin/main，可以在 Mac 和 iPhone 刷新订阅。"
