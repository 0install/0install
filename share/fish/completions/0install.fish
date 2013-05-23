function __fish_0install_complete
	begin;
		set -x COMP_CWORD (count (commandline --tokenize --cut-at-cursor))
		set args (commandline --tokenize)
		for item in (0install _complete fish $args)
			switch $item
				case 'add *'    ; echo $item | cut -c 5-
				case 'filter *' ; echo $item | cut -c 8-
				case 'prefix *' ; echo $item | cut -c 8-
				case 'file'     ; ; # noop
				case '*'        ; echo >&2 Bad reply $item
			end
		end
	end
end

complete -e -c 0install
complete -c 0install -a '(__fish_0install_complete)'
