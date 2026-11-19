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
selector="${rule%%,*},${${rule#*,}%%,*}"

# 串行处理两个配置，避免同时运行脚本时覆盖另一条规则。
zmodload zsh/system
zsystem flock -t 10 -f lock_fd "${0:A}" || die '另一份脚本正在更新配置，请稍后再试。'
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
  local file=$1 content line
  local -a lines
  local -i i in_rules=0 after=0
  # 保留原文件末尾的换行状态。
  content=$(cat -- "$file" && print -rn -- .)
  lines=("${(@f)${content%.}}")
  for (( i=1; i <= $#lines; ++i )); do
    line=${${lines[i]##[[:blank:]]#}%%[[:space:]]#}
    case $line in
      '[Rule]') in_rules=1; after=$i; continue ;;
      \[*\]) (( in_rules )) && break; continue ;;
      ''|'#'*|';'*) continue ;;
    esac
    (( in_rules )) || continue
    line=${line//[[:blank:]]#,[[:blank:]]#/,}
    [[ $line == "$rule" ]] && return 0
    [[ $line != "$selector,"* ]] || die "$file 已有不同设置：$line"
    [[ $line != (FINAL|MATCH),* ]] || break
    after=$i
  done
  (( after )) || die "$file 缺少 [Rule] 段。"

  local new_line=$rule
  [[ ${lines[after]} == *$'\r' ]] && new_line+=$'\r'
  lines[after,after]=("${lines[after]}" "$new_line")
  cp -p -- "$file" "$stage/$file.orig"
  cp -p -- "$file" "$stage/$file"
  print -rn -- "${(F)lines}" > "$stage/$file"
  changed+=("$file")
}

for file in sr_cnip_ex.conf sr_cnip_ad_ex.conf; do
  prepare "$file"
done
for file in "${changed[@]}"; do
  rollback+=("$file")
  mv -f -- "$stage/$file" "$file"
done
rollback=()
if (( $#changed )); then
  print -r -- "已写入 ${(j:、:)changed}：$rule"
else
  print -r -- "两份配置均已有此规则：$rule"
fi
