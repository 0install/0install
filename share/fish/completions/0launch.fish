function __fish_0launch_complete
	begin;
		set -x COMP_CWORD (count (commandline --tokenize --cut-at-cursor))
		set args (commandline --tokenize)
		for item in (0launch _complete fish $args)
			switch $item
				case 'add *'    ; echo $item | cut -c 5-
				case 'filter *' ; echo $item | cut -c 8-
				case 'prefix *' ; echo $item | cut -c 8-
				case 'file'     ;
					begin
						# echo needed to prevent empty list
						set arg (echo (commandline --tokenize --current-token))
						ls -1 (dirname {$arg}_) ^/dev/null
					end;
				case '*'        ; echo >&2 Bad reply $item
			end
		end
	end
end

complete -e -c 0launch
complete -c 0launch --no-files --arguments '(__fish_0launch_complete)'
