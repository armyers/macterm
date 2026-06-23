# macterm enhancements

- make contexts persist across reboots, similar to zellij and tmux/continuum. they serialize the state (scrollback, any process that is running that might be able to be restarted, etc). Obviously most running processes can't be resumed. But processes like vi can be restarted with its command line args). I think I have tmux and zellij to autosave every 15-20 seconds.
