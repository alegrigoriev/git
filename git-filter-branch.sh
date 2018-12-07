#!/bin/sh
#
# Rewrite revision history
# Copyright (c) Petr Baudis, 2006
# Minimal changes to "port" it to core-git (c) Johannes Schindelin, 2007
#
# Lets you rewrite the revision history of the current branch, creating
# a new branch. You can specify a number of filters to modify the commits,
# files and trees.

# The following functions will also be available in the commit filter:

functions=$(cat << \EOF
EMPTY_TREE=$(git hash-object -t tree /dev/null)

warn () {
	echo "$*" >&2
}

map()
{
	# if it was not rewritten, take the original
	if test -r "$workdir/../map/$1"
	then
		cat "$workdir/../map/$1"
	else
		echo "$1"
	fi
}

# if you run 'skip_commit "$@"' in a commit filter, it will print
# the (mapped) parents, effectively skipping the commit.

skip_commit()
{
	shift;
	while [ -n "$1" ];
	do
		shift;
		map "$1";
		shift;
	done;
}

# if you run 'git_commit_non_empty_tree "$@"' in a commit filter,
# it will skip commits that leave the tree untouched, commit the other.
git_commit_non_empty_tree()
{
	if test $# = 3 && test "$1" = $(git rev-parse "$3^{tree}"); then
		map "$3"
	elif test $# = 1 && test "$1" = $EMPTY_TREE; then
		:
	else
		git commit-tree "$@"
	fi
}
# override die(): this version puts in an extra line break, so that
# the progress is still visible

die()
{
	echo >&2
	echo "$*" >&2
	exit 1
}
EOF
)

eval "$functions"

finish_ident() {
	# Ensure non-empty id name.
	echo "case \"\$GIT_$1_NAME\" in \"\") GIT_$1_NAME=\"\${GIT_$1_EMAIL%%@*}\" && export GIT_$1_NAME;; esac"
	# And make sure everything is exported.
	echo "export GIT_$1_NAME"
	echo "export GIT_$1_EMAIL"
	echo "export GIT_$1_DATE"
}

set_ident () {
	parse_ident_from_commit author AUTHOR committer COMMITTER
	finish_ident AUTHOR
	finish_ident COMMITTER
}

# Call this in the trap to save the state to state-branch blob, delete temp directories
save_filter_branch_state () {
	local state_branch=$1
	local state_commit=$2
	echo "Saving rewrite state to $state_branch" 1>&2
	state_blob=$(
		perl -e'opendir D, "../map" or die;
			open H, "|-", "git hash-object -w --stdin" or die;
			foreach (sort readdir(D)) {
				next if m/^\.\.?$/;
				open F, "<../map/$_" or die;
				chomp($f = <F>);
				print H "$_:$f\n" or die;
			}
			close(H) or die;' || die "Unable to save state")
	# If the trees are being reconstructed, save the reconstructed tree map, as well
	if test -n "$3"
	then
		reconstructed_tree_blob=$(ls -1 ../reconstructed_tree_map | while read old_tree ; do
		echo "$old_tree:$(<../reconstructed_tree_map/$old_tree)"; done | git hash-object -w --stdin )
		state_tree=$(echo "100644 blob $state_blob	filter.map
100644 blob $reconstructed_tree_blob	reconstructed_tree.map" | git mktree)
	else
		state_tree=$(printf '100644 blob %s\tfilter.map\n' "$state_blob" | git mktree)
	fi
	if test -n "$state_commit"
	then
		state_commit=$(echo "Sync" | git commit-tree "$state_tree" -p "$state_commit")
	else
		state_commit=$(echo "Sync" | git commit-tree "$state_tree" )
	fi
	git update-ref "$state_branch" "$state_commit"
}

USAGE="[--setup <command>] [--subdirectory-filter <directory>] [--env-filter <command>]
	[--tree-filter <command>] [--index-filter <command>]
	[--parent-filter <command>] [--msg-filter <command>]
	[--commit-filter <command>] [--tag-name-filter <command>]
	[--original <namespace>]
	[-d <directory>] [-f | --force] [--state-branch <branch>]
	[--index-pre-filter <command>] [--diff-tree-filter <command>]
	[--renormalize]
	[--] [<rev-list options>...]"

OPTIONS_SPEC=
. git-sh-setup

if [ "$(is_bare_repository)" = false ]; then
	require_clean_work_tree 'rewrite branches'
fi

tempdir=.git-rewrite
filter_setup=
filter_env=
filter_tree=
filter_index=
filter_parent=
filter_msg=cat
filter_commit=
filter_tag_name=
filter_subdir=
state_branch=
prefilter_index=
diff_tree_filter=
renormalize=
orig_namespace=refs/original/
force=
prune_empty=
filter_gitmodules=
remap_to_ancestor=
while :
do
	case "$1" in
	--)
		shift
		break
		;;
	--force|-f)
		shift
		force=t
		continue
		;;
	--remap-to-ancestor)
		# deprecated ($remap_to_ancestor is set now automatically)
		shift
		remap_to_ancestor=t
		continue
		;;
	--prune-empty)
		shift
		prune_empty=t
		continue
		;;
	--filter-gitmodules)
		shift
		filter_gitmodules=t
		continue
		;;
	--renormalize)
		shift
		renormalize=t
		remap_to_ancestor=t
		continue
		;;
	-*)
		;;
	*)
		break;
	esac

	# all switches take one argument
	ARG="$1"
	case "$#" in 1) usage ;; esac
	shift
	OPTARG="$1"
	shift

	case "$ARG" in
	-d)
		tempdir="$OPTARG"
		;;
	--setup)
		filter_setup="$OPTARG"
		;;
	--subdirectory-filter)
		filter_subdir="$OPTARG"
		remap_to_ancestor=t
		;;
	--env-filter)
		filter_env="$OPTARG"
		;;
	--tree-filter)
		filter_tree="$OPTARG"
		;;
	--index-filter)
		filter_index="$OPTARG"
		;;
	--parent-filter)
		filter_parent="$OPTARG"
		;;
	--msg-filter)
		filter_msg="$OPTARG"
		;;
	--commit-filter)
		filter_commit="$functions; $OPTARG"
		;;
	--tag-name-filter)
		filter_tag_name="$OPTARG"
		;;
	--original)
		orig_namespace=$(expr "$OPTARG/" : '\(.*[^/]\)/*$')/
		;;
	--state-branch)
		state_branch="$OPTARG"
		;;
	--index-pre-filter)
		prefilter_index="$OPTARG"
		remap_to_ancestor=t
		;;
	--diff-tree-filter)
		diff_tree_filter="$OPTARG"
		remap_to_ancestor=t
		;;
	*)
		usage
		;;
	esac
done

case "$prune_empty,$filter_commit" in
,)
	filter_commit='git commit-tree "$@"';;
t,)
	filter_commit="$functions;"' git_commit_non_empty_tree "$@"';;
,*)
	;;
*)
	die "Cannot set --prune-empty and --commit-filter at the same time"
esac

case "$force" in
t)
	rm -rf "$tempdir"
;;
'')
	test -d "$tempdir" &&
		die "$tempdir already exists, please remove it"
esac
orig_dir=$(pwd)
mkdir -p "$tempdir/t" &&
tempdir="$(cd "$tempdir"; pwd)" &&
cd "$tempdir/t" &&
workdir="$(pwd)" ||
die ""

# Remove tempdir on exit
trap 'cd "$orig_dir"; rm -rf "$tempdir"' 0

ORIG_GIT_DIR="$GIT_DIR"
ORIG_GIT_WORK_TREE="$GIT_WORK_TREE"
ORIG_GIT_INDEX_FILE="$GIT_INDEX_FILE"
ORIG_GIT_AUTHOR_NAME="$GIT_AUTHOR_NAME"
ORIG_GIT_AUTHOR_EMAIL="$GIT_AUTHOR_EMAIL"
ORIG_GIT_AUTHOR_DATE="$GIT_AUTHOR_DATE"
ORIG_GIT_COMMITTER_NAME="$GIT_COMMITTER_NAME"
ORIG_GIT_COMMITTER_EMAIL="$GIT_COMMITTER_EMAIL"
ORIG_GIT_COMMITTER_DATE="$GIT_COMMITTER_DATE"

GIT_WORK_TREE=.
export GIT_DIR GIT_WORK_TREE

# Make sure refs/original is empty
git for-each-ref > "$tempdir"/backup-refs || exit
while read sha1 type name
do
	case "$force,$name" in
	,$orig_namespace*)
		die "Cannot create a new backup.
A previous backup already exists in $orig_namespace
Force overwriting the backup with -f"
	;;
	t,$orig_namespace*)
		git update-ref -d "$name" $sha1
	;;
	esac
done < "$tempdir"/backup-refs

# The refs should be updated if their heads were rewritten
git rev-parse --no-flags --revs-only --symbolic-full-name \
	--default HEAD "$@" > "$tempdir"/raw-refs || exit
while read ref
do
	case "$ref" in ^?*) continue ;; esac

	if git rev-parse --verify "$ref"^0 >/dev/null 2>&1
	then
		echo "$ref"
	else
		warn "WARNING: not rewriting '$ref' (not a committish)"
	fi
done >"$tempdir"/heads <"$tempdir"/raw-refs

test -s "$tempdir"/heads ||
	die "You must specify a ref to rewrite."

GIT_INDEX_FILE="$(pwd)/../index"
export GIT_INDEX_FILE

# map old->new commit ids for rewriting parents
mkdir ../map || die "Could not create map/ directory"

if test -n "$renormalize" && test -z "$diff_tree_filter"
then
	diff_tree_filter=cat
fi

if test -n "$diff_tree_filter"
then
	# map old->new tree ids for reconstricting new tree from diffs
	mkdir ../reconstructed_tree_map || die "Could not create map/ directory"
fi

if test -n "$state_branch"
then
	state_commit=$(git rev-parse --no-flags --revs-only "$state_branch")
	if test -n "$state_commit"
	then
		echo "Populating map from $state_branch ($state_commit)" 1>&2
		perl -e'open(MAP, "-|", "git show $ARGV[0]:filter.map") or die;
			while (<MAP>) {
				m/(.*):(.*)/ or die;
				open F, ">../map/$1" or die;
				print F "$2" or die;
				close(F) or die;
			}
			close(MAP) or die;' "$state_commit" \
				|| die "Unable to load state from $state_branch:filter.map"
		if test -n "$diff_tree_filter"
		then
			# restore old->new tree mappings for reconstricting new tree from diffs
			git show $state_commit:reconstructed_tree.map | while IFS=':' read old_tree new_tree; do
				echo $new_tree >../reconstructed_tree_map/$old_tree
			done
		fi
	else
		echo "Branch $state_branch does not exist. Will create" 1>&2
	fi
	# On the script abort, save the state to state-branch blob, delete temp directories
	trap "save_filter_branch_state $state_branch \"$state_commit\" ${diff_tree_filter:+t}
		cd \"$orig_dir\"; rm -rf \"$tempdir\"" 0
fi

# we need "--" only if there are no path arguments in $@
nonrevs=$(git rev-parse --no-revs "$@") || exit
if test -z "$nonrevs"
then
	dashdash=--
else
	dashdash=
	remap_to_ancestor=t
fi

git rev-parse --revs-only "$@" >../parse

case "$filter_subdir" in
"")
	eval set -- "$(git rev-parse --sq --no-revs "$@")"
	;;
*)
	eval set -- "$(git rev-parse --sq --no-revs "$@" $dashdash \
		"$filter_subdir")"
	;;
esac

git rev-list --reverse --topo-order --default HEAD \
	--parents --simplify-merges --stdin "$@" <../parse >../revs ||
	die "Could not get the commits"
commits=$(wc -l <../revs | tr -d " ")

test $commits -eq 0 && die_with_status 2 "Found nothing to rewrite"

# Rewrite the commits
report_progress ()
{
	local count effective_count now elapsed remaining
	count=$git_filter_branch__commit_count
	effective_count=$(($count - $git_filter_branch__skipped_commits))

	if test -n "$progress" &&
		test $count -gt $next_sample_at
	then

		now=$(date +%s)
		elapsed=$(($now - $start_timestamp))
		if test $elapsed -gt 5 && test $effective_count -gt 0
		then
			next_sample_at=$(( ($elapsed + 1) * $effective_count / $elapsed ))
			remaining=$(( ($commits - $count) * $elapsed / $effective_count ))
			progress=" ($elapsed seconds passed, remaining $remaining predicted)"
		else
			next_sample_at=$(($next_sample_at + 1))
			progress=" ($elapsed seconds passed)"
		fi
	fi
	printf "\rRewrite $commit ($count/$commits)$progress    "
}

git_filter_branch__commit_count=0
# Number of commits skipped because they've been processed in previous invocation of filter-branch
git_filter_branch__skipped_commits=0

progress= start_timestamp=
if date '+%s' 2>/dev/null | grep -q '^[0-9][0-9]*$'
then
	next_sample_at=0
	progress="dummy to ensure this is not empty"
	start_timestamp=$(date '+%s')
fi

if test -n "$filter_index" ||
   test -n "$prefilter_index" ||
   test -n "$filter_tree" ||
   { test -n "$filter_subdir" && test -n "$filter_gitmodules"; }
then
	need_index=t
else
	need_index=
fi

eval "$filter_setup" < /dev/null ||
	die "filter setup failed: $filter_setup"

last_gitmodules=
current_gitmodules_adjusted=

if test -n "$diff_tree_filter" ||
	test -n "$filter_subdir"
then
	# Make sure we have a NULL tree object available
	git read-tree --empty
	null_tree=$(git write-tree)
fi

last_gitattributes_checked_out=$null_tree

while read commit parents; do
	git_filter_branch__commit_count=$(($git_filter_branch__commit_count+1))

	test -f "$workdir"/../map/$commit && git_filter_branch__skipped_commits=$(($git_filter_branch__skipped_commits+1)) continue
	report_progress

	case "$filter_subdir" in
	"")
		tree=$(git rev-parse "$commit^{tree}")
		;;
	*)
		# The commit may not have the subdirectory at all, if the directory was deleted?
		if tree=$(git rev-parse $commit:"$filter_subdir" 2>/dev/null )
		then
			if test -n "$filter_gitmodules" && current_gitmodules=$(git rev-parse $commit:.gitmodules 2>/dev/null )
			then
				if [ "$current_gitmodules" != "$last_gitmodules" ]
				then
					# Build new .gitmodules file, with the paths adjusted to the new directory,
					# and remove those with paths outside the filtered directory
					git show $commit:.gitmodules >|../.gitmodules

					git config --file ../.gitmodules --list | {
						submodule_keys=
						while read name value; do
							if [[ "$name" = submodule.*.path ]]
							then
								submodule_keys+=" $name"
							fi
						done
						for path_key in $submodule_keys ; do
							submodule_path=$(git config --file ../.gitmodules --get $path_key)
							if [ "${submodule_path#$filter_subdir/}" = "$submodule_path" ]
							then
								# The path is outside of the filtered directory
								git config --file ../.gitmodules --remove-section ${path_key%.path}
							else
								git config --file ../.gitmodules $path_key "${submodule_path#$filter_subdir/}"
							fi
						done
					}
					current_gitmodules_adjusted=$(git hash-object -t blob -w --path=.gitmodules -- ../.gitmodules )
					last_gitmodules=$current_gitmodules
				fi
			else
			# No .gitmodules in the original commit
			last_gitmodules=
			current_gitmodules_adjusted=
			fi
		else
			# The directory was deleted from the history in this commit.
			# The empty tree will not be saved as a commit by git_commit_non_empty_tree
			# But we have an opportunity to apply tree-filter or index-filter on it
			tree=$null_tree
			last_gitmodules=
			current_gitmodules_adjusted=
		fi
	esac

	GIT_COMMIT=$commit
	export GIT_COMMIT
	git cat-file commit "$commit" >../commit ||
		die "Cannot read commit $commit"

	eval "$(set_ident <../commit)" ||
		die "setting author/committer failed for commit $commit"
	eval "$filter_env" < /dev/null ||
		die "env filter failed: $filter_env"

	if [ "$diff_tree_filter" ]
	then
		# diff the tree from its parent trees. Whichever files change (or added) we add to the index.
		# In other words, we manually recreate the new index from the new commit parent and difference in the trees
		# 
		# Thus, in case the operation doesn't start from the null parent, it's compared against null tree.
		# Because tree-filter and index-(post)filter can change the trees, we keep a separate map for them

		parent_tree=$null_tree
		for parent in $parents; do
			if [ "$filter_subdir" ]
			then
				if ! parent_tree=$(git rev-parse $parent:"$filter_subdir" 2>/dev/null )
					then parent_tree=$null_tree; fi
			else
				parent_tree=$(git rev-parse "$parent^{tree}")
			fi
			#only the first parent used
			break
		done

		# The new tree will be built off the first reconstructed parent, and the tree diff
		# get reconstructed parent trees from norm_map
		if test -r "../reconstructed_tree_map/$parent_tree"
		then
			reconstructed_parent=$(cat <"../reconstructed_tree_map/$parent_tree" )
		else
			# Reconstructed parent tree for this commit doesn't exist.
			# This means the tree has to be rebuilt fully.
			# To do that, we use a NULL tree for comparison
			parent_tree=$null_tree
			reconstructed_parent=$null_tree
		fi

		git --no-replace-objects read-tree -i -m $reconstructed_parent ||
			die "Could not initialize the index"

		if test -n "$current_gitmodules_adjusted" ;then git update-index --cacheinfo 100644,$current_gitmodules_adjusted,.gitmodules ;fi

		# index-pre-filter can add or replace .gitattributes, or add other files.
		eval "$prefilter_index" < /dev/null ||
			die "index pre-filter failed: $prefilter_index"

		if test -n "$renormalize"
		then
			# During renormalization, hash-object doesn't consider .gitattributes when they're not in the work tree
			# We need to checkout all changed .gitattributes in the tree, and delete all deleted
			git diff-index -m --cached --no-renames --ignore-submodules=all --name-status $last_gitattributes_checked_out -- .gitattributes "**/.gitattributes" | \
				while read operation object_path ; do
				case $operation in
					M|A)
						# checkout the file
						git checkout-index -q -f -- "$object_path" ;;
					D)
						#delete the file
						rm "$object_path" ;;
					*)
					#nothing
					;;
				esac
			done
		fi

		git diff-tree -r --no-renames $parent_tree $tree | {
			while read mode1 mode2 obj_id1 obj_id2 operation object_path ; do
			# Apply these diffs to the index

			if [ $obj_id2 != 0000000000000000000000000000000000000000 ] &&
			# else hash==00000000... - the entry is being deleted, can't rehash it
				test -n "$renormalize" && [ $mode2 != 160000 ]
			then
				# mode 160000 - a submodule, don't pass through hash-object
				# Symbolic links (mode 120000) will still get passed through hash-object, to
				# give it an opportunity to substitute a replace ref.
				obj_id2=$(git cat-file blob $obj_id2 |
					git hash-object -t blob -w --stdin --path "$object_path" 2>/dev/null )
				# add this path as a newly normalized blob
			fi

			if [ "$diff_tree_filter" != cat ]
			then
				# diff-tree filter - can modify mode or path, or drop the file altogether!
				# You can also check if .gitattributes was modified and drop this line
				echo -e "$mode2 $obj_id2 0\t$object_path" | eval "$diff_tree_filter"
			else
				echo -e "$mode2 $obj_id2 0\t$object_path"
			fi
		done | git --no-replace-objects update-index --index-info || die "update-index failed for normalization"
		
		reconstructed_tree=$(git --no-replace-objects write-tree)
		
		if [ $tree != $null_tree ]
		then
			#update the reconstructed tree map
			echo $reconstructed_tree >../reconstructed_tree_map/$tree
		fi
		tree=$reconstructed_tree
		last_gitattributes_checked_out=$tree
		#don't need to read the tree anymore
	elif [ "$need_index" ]
	then
		git read-tree -i -m $tree || die "Could not initialize the index"
		if test -n "$current_gitmodules_adjusted" ;then git update-index --cacheinfo 100644,$current_gitmodules_adjusted,.gitmodules ;fi

		# index_pre_filter can add or replace .gitattributes, or add other files.
		if test -n "$prefilter_index"
		then 
			eval "$prefilter_index" < /dev/null ||
				die "index pre-filter failed: $prefilter_index"
			tree=$(git write-tree)
		fi
	fi

	if [ "$filter_tree" ]; then
		git checkout-index -f -u -a ||
			die "Could not checkout the index"
		# files that $commit removed are now still in the working tree;
		# remove them, else they would be added again
		git clean -d -q -f -x
		eval "$filter_tree" < /dev/null ||
			die "tree filter failed: $filter_tree"

		(
			git diff-index -r --name-only --ignore-submodules $tree -- &&
			git ls-files --others
		) > "$tempdir"/tree-state || exit
		git update-index --add --replace --remove --stdin \
			< "$tempdir"/tree-state || exit

		if test -n "$renormalize_filter"
		then
			# The working tree changed, we need to save it now, to check out .gitattributes on the next turn
			last_gitattributes_checked_out=$(git write-tree)
		fi
	fi

	eval "$filter_index" < /dev/null ||
		die "index filter failed: $filter_index"

	parentstr=
	for parent in $parents; do
		for reparent in $(map "$parent"); do
			case "$parentstr " in
			*" -p $reparent "*)
				;;
			*)
				parentstr="$parentstr -p $reparent"
				;;
			esac
		done
	done
	if [ "$filter_parent" ]; then
		parentstr="$(echo "$parentstr" | eval "$filter_parent")" ||
				die "parent filter failed: $filter_parent"
	fi

	{
		while IFS='' read -r header_line && test -n "$header_line"
		do
			# skip header lines...
			:;
		done
		# and output the actual commit message
		cat
	} <../commit |
		eval "$filter_msg" > ../message ||
			die "msg filter failed: $filter_msg"

	if test -n "$need_index"
	then
		tree=$(git write-tree)
	fi
	workdir=$workdir @SHELL_PATH@ -c "$filter_commit" "git commit-tree" \
		$tree $parentstr < ../message > ../map/$commit ||
			die "could not write rewritten commit"
done <../revs

# If we are filtering for paths, as in the case of a subdirectory
# filter, it is possible that a specified head is not in the set of
# rewritten commits, because it was pruned by the revision walker.
# Ancestor remapping fixes this by mapping these heads to the unique
# nearest ancestor that survived the pruning.

if test "$remap_to_ancestor" = t
then
	while read ref
	do
		sha1=$(git rev-parse "$ref"^0)
		test -f "$workdir"/../map/$sha1 && continue
		ancestor=$(git rev-list --simplify-merges -1 "$ref" "$@")
		test "$ancestor" && echo $(map $ancestor) >> "$workdir"/../map/$sha1
	done < "$tempdir"/heads
fi

# Finally update the refs

_x40='[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]'
_x40="$_x40$_x40$_x40$_x40$_x40$_x40$_x40$_x40"
echo
while read ref
do
	# avoid rewriting a ref twice
	test -f "$orig_namespace${ref#refs/}" && continue

	sha1=$(git rev-parse "$ref"^0)
	rewritten=$(map $sha1)

	test $sha1 = "$rewritten" &&
		warn "WARNING: Ref '$ref' is unchanged" &&
		continue

	case "$rewritten" in
	'')
		echo "Ref '$ref' was deleted"
		git update-ref -m "filter-branch: delete" -d "$ref" $sha1 ||
			die "Could not delete $ref"
	;;
	$_x40)
		echo "Ref '$ref' was rewritten"
		if ! git update-ref -m "filter-branch: rewrite" \
					"$ref" $rewritten $sha1 2>/dev/null; then
			if test $(git cat-file -t "$ref") = tag; then
				if test -z "$filter_tag_name"; then
					warn "WARNING: You said to rewrite tagged commits, but not the corresponding tag."
					warn "WARNING: Perhaps use '--tag-name-filter cat' to rewrite the tag."
				fi
			else
				die "Could not rewrite $ref"
			fi
		fi
	;;
	*)
		# NEEDSWORK: possibly add -Werror, making this an error
		warn "WARNING: '$ref' was rewritten into multiple commits:"
		warn "$rewritten"
		warn "WARNING: Ref '$ref' points to the first one now."
		rewritten=$(echo "$rewritten" | head -n 1)
		git update-ref -m "filter-branch: rewrite to first" \
				"$ref" $rewritten $sha1 ||
			die "Could not rewrite $ref"
	;;
	esac
	git update-ref -m "filter-branch: backup" "$orig_namespace${ref#refs/}" $sha1 ||
		 exit
done < "$tempdir"/heads

# TODO: This should possibly go, with the semantics that all positive given
#       refs are updated, and their original heads stored in refs/original/
# Filter tags

if [ "$filter_tag_name" ]; then
	git for-each-ref --format='%(objectname) %(objecttype) %(refname)' refs/tags |
	while read sha1 type ref; do
		ref="${ref#refs/tags/}"
		# XXX: Rewrite tagged trees as well?
		if [ "$type" != "commit" -a "$type" != "tag" ]; then
			continue;
		fi

		if [ "$type" = "tag" ]; then
			# Dereference to a commit
			sha1t="$sha1"
			sha1="$(git rev-parse -q "$sha1"^{commit})" || continue
		fi

		[ -f "../map/$sha1" ] || continue
		new_sha1="$(cat "../map/$sha1")"
		GIT_COMMIT="$sha1"
		export GIT_COMMIT
		new_ref="$(echo "$ref" | eval "$filter_tag_name")" ||
			die "tag name filter failed: $filter_tag_name"

		echo "$ref -> $new_ref ($sha1 -> $new_sha1)"

		if [ "$type" = "tag" ]; then
			new_sha1=$( ( printf 'object %s\ntype commit\ntag %s\n' \
						"$new_sha1" "$new_ref"
				git cat-file tag "$ref" |
				sed -n \
				    -e '1,/^$/{
					  /^object /d
					  /^type /d
					  /^tag /d
					}' \
				    -e '/^-----BEGIN PGP SIGNATURE-----/q' \
				    -e 'p' ) |
				git hash-object -t tag -w --stdin) ||
				die "Could not create new tag object for $ref"
			if git cat-file tag "$ref" | \
			   sane_grep '^-----BEGIN PGP SIGNATURE-----' >/dev/null 2>&1
			then
				warn "gpg signature stripped from tag object $sha1t"
			fi
		fi

		git update-ref "refs/tags/$new_ref" "$new_sha1" ||
			die "Could not write tag $new_ref"
	done
fi

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_AUTHOR_DATE
unset GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL GIT_COMMITTER_DATE
test -z "$ORIG_GIT_DIR" || {
	GIT_DIR="$ORIG_GIT_DIR" && export GIT_DIR
}
test -z "$ORIG_GIT_WORK_TREE" || {
	GIT_WORK_TREE="$ORIG_GIT_WORK_TREE" &&
	export GIT_WORK_TREE
}
test -z "$ORIG_GIT_INDEX_FILE" || {
	GIT_INDEX_FILE="$ORIG_GIT_INDEX_FILE" &&
	export GIT_INDEX_FILE
}
test -z "$ORIG_GIT_AUTHOR_NAME" || {
	GIT_AUTHOR_NAME="$ORIG_GIT_AUTHOR_NAME" &&
	export GIT_AUTHOR_NAME
}
test -z "$ORIG_GIT_AUTHOR_EMAIL" || {
	GIT_AUTHOR_EMAIL="$ORIG_GIT_AUTHOR_EMAIL" &&
	export GIT_AUTHOR_EMAIL
}
test -z "$ORIG_GIT_AUTHOR_DATE" || {
	GIT_AUTHOR_DATE="$ORIG_GIT_AUTHOR_DATE" &&
	export GIT_AUTHOR_DATE
}
test -z "$ORIG_GIT_COMMITTER_NAME" || {
	GIT_COMMITTER_NAME="$ORIG_GIT_COMMITTER_NAME" &&
	export GIT_COMMITTER_NAME
}
test -z "$ORIG_GIT_COMMITTER_EMAIL" || {
	GIT_COMMITTER_EMAIL="$ORIG_GIT_COMMITTER_EMAIL" &&
	export GIT_COMMITTER_EMAIL
}
test -z "$ORIG_GIT_COMMITTER_DATE" || {
	GIT_COMMITTER_DATE="$ORIG_GIT_COMMITTER_DATE" &&
	export GIT_COMMITTER_DATE
}

trap - 0

if test -n "$state_branch"
then
	save_filter_branch_state $state_branch "$state_commit" ${diff_tree_filter:+t}
fi

cd "$orig_dir"
rm -rf "$tempdir"

if [ "$(is_bare_repository)" = false ]; then
	git read-tree -u -m HEAD || exit
fi

exit 0
