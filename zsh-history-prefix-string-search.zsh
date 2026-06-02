#!/usr/bin/env zsh
##############################################################################
#
# Copyright (c) 2009 Peter Stephenson
# Copyright (c) 2011 Guido van Steen
# Copyright (c) 2011 Suraj N. Kurapati
# Copyright (c) 2011 Sorin Ionescu
# Copyright (c) 2011 Vincent Guerci
# Copyright (c) 2016 Geza Lore
# Copyright (c) 2017 Bengt Brodersen
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
#  * Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
#
#  * Redistributions in binary form must reproduce the above
#    copyright notice, this list of conditions and the following
#    disclaimer in the documentation and/or other materials provided
#    with the distribution.
#
#  * Neither the name of the FIZSH nor the names of its contributors
#    may be used to endorse or promote products derived from this
#    software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
# LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.
#
##############################################################################

#-----------------------------------------------------------------------------
# declare global configuration variables
#-----------------------------------------------------------------------------

: ${HISTORY_SUBSTRING_SEARCH_GLOBBING_FLAGS='i'}
: ${HISTORY_SUBSTRING_SEARCH_ENSURE_UNIQUE=''}
: ${HISTORY_SUBSTRING_SEARCH_SUGGESTION_HIGHLIGHT_STYLE='fg=8'}

# Acceptance is delegated to zsh-autosuggestions.  Our plugin only manages
# prefix matching and sets POSTDISPLAY; zsh-autosuggestions' own widget
# wrappers handle partial accept (char/word/all) according to the user's
# ZSH_AUTOSUGGEST_* configuration.

#-----------------------------------------------------------------------------
# declare internal global variables
#-----------------------------------------------------------------------------

typeset -g BUFFER MATCH MBEGIN MEND CURSOR
typeset -g _history_substring_search_result
typeset -g _history_substring_search_query
typeset -g _history_substring_search_prefix
typeset -g _history_substring_search_suggestion
typeset -g -a _history_substring_search_raw_matches
typeset -g -i _history_substring_search_raw_match_index
typeset -g -a _history_substring_search_matches
typeset -g -i _history_substring_search_match_index
typeset -g -A _history_substring_search_unique_filter
typeset -g -i _history_substring_search_zsh_5_9

#-----------------------------------------------------------------------------
# the main ZLE widgets
#-----------------------------------------------------------------------------

history-substring-search-up() {
  _history-substring-search-begin

  _history-substring-search-up-history ||
  _history-substring-search-up-buffer ||
  _history-substring-search-up-search

  _history-substring-search-end
}

history-substring-search-down() {
  _history-substring-search-begin

  _history-substring-search-down-history ||
  _history-substring-search-down-buffer ||
  _history-substring-search-down-search

  _history-substring-search-end
}

zle -N history-substring-search-up
zle -N history-substring-search-down

#-----------------------------------------------------------------------------
# implementation details
#-----------------------------------------------------------------------------

zmodload -F zsh/parameter
autoload -Uz is-at-least

if is-at-least 5.9 $ZSH_VERSION; then
  _history_substring_search_zsh_5_9=1
fi

#-----------------------------------------------------------------------------
# POSTDISPLAY grey-suffix hook.
#
# Runs on every ZLE redraw after zsh-syntax-highlighting's own hook, so
# syntax colours stay intact and we only add the plugin-specific suffix
# highlight.
#-----------------------------------------------------------------------------
if [[ $_history_substring_search_zsh_5_9 -eq 1 ]] && autoload -Uz +X add-zle-hook-widget 2>/dev/null; then
  autoload -Uz add-zle-hook-widget

  _history-substring-search-suffix-pre-redraw() {
    # Remove only our own suffix highlights.
    region_highlight=( "${(@)region_highlight:#*memo=history-substring-search*}" )

    if [[ -n $POSTDISPLAY ]]; then
      local start=${#BUFFER}
      local end=$(( start + ${#POSTDISPLAY} ))
      region_highlight+=( "${start} ${end} ${HISTORY_SUBSTRING_SEARCH_SUGGESTION_HIGHLIGHT_STYLE},memo=history-substring-search" )
      # Ensure cursor stays in the real buffer.
      (( CURSOR > ${#BUFFER} )) && CURSOR=${#BUFFER}
    fi
  }

  if [[ -o zle ]]; then
    add-zle-hook-widget zle-line-pre-redraw _history-substring-search-suffix-pre-redraw
  fi
fi

_history-substring-search-begin() {
  setopt localoptions extendedglob

  #
  # If the buffer is the same as the active prefix, then just keep stepping
  # through the match list. The selected history command is rendered through
  # POSTDISPLAY and is not written into BUFFER.
  #
  if [[ -n $BUFFER && $BUFFER == "${_history_substring_search_prefix:-}" ]]; then
    return;
  fi

  #
  # Clear the previous result.
  #
  _history_substring_search_result=''
  _history_substring_search_suggestion=''
  POSTDISPLAY=

  if [[ -z $BUFFER ]]; then
    #
    # If the buffer is empty, we will just act like up-history/down-history
    # in ZSH, so we do not need to actually search the history. This should
    # speed things up a little.
    #
    _history_substring_search_query=
    _history_substring_search_prefix=
    _history_substring_search_raw_matches=()

  else
    #
    # For the purpose of highlighting we keep a copy of the original
    # query string.
    #
    _history_substring_search_query=$BUFFER
    _history_substring_search_prefix=$BUFFER

    #
    # Escape the literal prefix and append a single trailing wildcard.
    # This plugin now does strict prefix matching: BUFFER must be the start of
    # the history entry. It intentionally does not prepend '*'.
    #
    local search_pattern="${_history_substring_search_query//(#m)[\][()|\\*?#<>~^]/\\$MATCH}*"

    #
    # Find all prefix occurrences of the search pattern in the history file.
    #
    # (k) returns the "keys" (history index numbers) instead of the values
    # (R) returns values in reverse older, so the index of the youngest
    # matching history entry is at the head of the list.
    #
    _history_substring_search_raw_matches=(${(k)history[(R)(#$HISTORY_SUBSTRING_SEARCH_GLOBBING_FLAGS)${search_pattern}]})
  fi

  #
  # In order to stay as responsive as possible, we will process the raw
  # matches lazily (when the user requests the next match) to choose items
  # that need to be displayed to the user.
  # _history_substring_search_raw_match_index holds the index of the last
  # unprocessed entry in _history_substring_search_raw_matches. Any items
  # that need to be displayed will be added to
  # _history_substring_search_matches.
  #
  # We use an associative array (_history_substring_search_unique_filter) as
  # a 'set' data structure so identical history entries are shown only once.
  # If an entry (key) is in the set (non-empty value), then we have already
  # added that entry to _history_substring_search_matches.
  #
  _history_substring_search_raw_match_index=0
  _history_substring_search_matches=()
  _history_substring_search_unique_filter=()

  #
  # If $_history_substring_search_match_index is equal to
  # $#_history_substring_search_matches + 1, this indicates that we
  # are beyond the end of $_history_substring_search_matches and that we
  # have also processed all entries in
  # _history_substring_search_raw_matches.
  #
  # If $#_history_substring_search_match_index is equal to 0, this indicates
  # that we are beyond the beginning of $_history_substring_search_matches.
  #
  # If we have initially pressed "up" we have to initialize
  # $_history_substring_search_match_index to 0 so that it will be
  # incremented to 1.
  #
  # If we have initially pressed "down" we have to initialize
  # $_history_substring_search_match_index to 1 so that it will be
  # decremented to 0.
  #
  if [[ $WIDGET == history-substring-search-down ]]; then
     _history_substring_search_match_index=1
  else
    _history_substring_search_match_index=0
  fi
}

_history-substring-search-end() {
  _history_substring_search_result=$_history_substring_search_suggestion

  # Keep the cursor at the end of the real buffer.  The pre-redraw hook
  # applies the grey POSTDISPLAY suffix highlight on every redraw.
  CURSOR=${#BUFFER}
  zle -R

  return 0
}

_history-substring-search-up-buffer() {
  #
  # Check if the UP arrow was pressed to move the cursor within a multi-line
  # buffer. This amounts to three tests:
  #
  # 1. $#buflines -gt 1.
  #
  # 2. $CURSOR -ne $#BUFFER.
  #
  # 3. Check if we are on the first line of the current multi-line buffer.
  #    If so, pressing UP would amount to leaving the multi-line buffer.
  #
  #    We check this by adding an extra "x" to $LBUFFER, which makes
  #    sure that xlbuflines is always equal to the number of lines
  #    until $CURSOR (including the line with the cursor on it).
  #
  local buflines XLBUFFER xlbuflines
  buflines=(${(f)BUFFER})
  XLBUFFER=$LBUFFER"x"
  xlbuflines=(${(f)XLBUFFER})

  if [[ $#buflines -gt 1 && $CURSOR -ne $#BUFFER && $#xlbuflines -ne 1 ]]; then
    zle up-line-or-history
    return 0
  fi

  return 1
}

_history-substring-search-down-buffer() {
  #
  # Check if the DOWN arrow was pressed to move the cursor within a multi-line
  # buffer. This amounts to three tests:
  #
  # 1. $#buflines -gt 1.
  #
  # 2. $CURSOR -ne $#BUFFER.
  #
  # 3. Check if we are on the last line of the current multi-line buffer.
  #    If so, pressing DOWN would amount to leaving the multi-line buffer.
  #
  #    We check this by adding an extra "x" to $RBUFFER, which makes
  #    sure that xrbuflines is always equal to the number of lines
  #    from $CURSOR (including the line with the cursor on it).
  #
  local buflines XRBUFFER xrbuflines
  buflines=(${(f)BUFFER})
  XRBUFFER="x"$RBUFFER
  xrbuflines=(${(f)XRBUFFER})

  if [[ $#buflines -gt 1 && $CURSOR -ne $#BUFFER && $#xrbuflines -ne 1 ]]; then
    zle down-line-or-history
    return 0
  fi

  return 1
}

_history-substring-search-up-history() {
  #
  # Behave like up in ZSH, except clear the $BUFFER
  # when beginning of history is reached like in Fish.
  #
  if [[ -z $_history_substring_search_query ]]; then

    # we have reached the absolute top of history
    if [[ $HISTNO -eq 1 ]]; then
      BUFFER=

    # going up from somewhere below the top of history
    else
      zle up-line-or-history
    fi

    # Remember the new BUFFER as the prefix so that subsequent
    # Up/Down presses keep doing standard history navigation
    # instead of switching to prefix matching.
    _history_substring_search_prefix=$BUFFER

    return 0
  fi

  return 1
}

_history-substring-search-down-history() {
  #
  # Behave like down-history in ZSH, except clear the
  # $BUFFER when end of history is reached like in Fish.
  #
  if [[ -z $_history_substring_search_query ]]; then

    # going down from the absolute top of history
    if [[ $HISTNO -eq 1 && -z $BUFFER ]]; then
      BUFFER=${history[1]}

    # going down from somewhere above the bottom of history
    else
      zle down-line-or-history
    fi

    _history_substring_search_prefix=$BUFFER

    return 0
  fi

  return 1
}

_history_substring_search_process_raw_matches() {
  #
  # Process more outstanding raw matches and append any matches that need to
  # be displayed to the user to _history_substring_search_matches.
  # Return whether there were any more results appended.
  #

  #
  # While we have more raw matches. Process them to see if there are any more
  # matches that need to be displayed to the user.
  #
  while [[ $_history_substring_search_raw_match_index -lt $#_history_substring_search_raw_matches ]]; do
    #
    # Move on to the next raw entry and get its history index.
    #
    _history_substring_search_raw_match_index+=1
    local index=${_history_substring_search_raw_matches[$_history_substring_search_raw_match_index]}

    #
    #
    # Skip exact-buffer matches. If the current prefix already equals a full
    # history entry, there is no suffix left to suggest.
    #
    local entry=${history[$index]}
    if [[ $entry == "$_history_substring_search_query" ]]; then
      continue
    fi

    #
    # Show each distinct history entry at most once, even if it appears
    # multiple times in history.
    #
    if [[ -n ${_history_substring_search_unique_filter[$entry]} ]]; then
      continue
    fi

    _history_substring_search_unique_filter[$entry]=1
    _history_substring_search_matches+=($index)

    #
    # Indicate that we did find a match.
    #
    return 0

  done

  #
  # We are beyond the end of the list of raw matches. Indicate that no
  # more matches are available.
  #
  return 1
}

_history-substring-search-has-next() {
  #
  # Predicate function that returns whether any more older matches are
  # available.
  #

  if  [[ $_history_substring_search_match_index -lt $#_history_substring_search_matches ]]; then
    #
    # We did not reach the end of the processed list, so we do have further
    # matches.
    #
    return 0

  else
    #
    # We are at the end of the processed list. Try to process further
    # unprocessed matches. _history_substring_search_process_raw_matches
    # returns whether any more matches were available, so just return
    # that result.
    #
    _history_substring_search_process_raw_matches
    return $?
  fi
}

_history-substring-search-has-prev() {
  #
  # Predicate function that returns whether any more younger matches are
  # available.
  #

  if [[ $_history_substring_search_match_index -gt 1 ]]; then
    #
    # We did not reach the beginning of the processed list, so we do have
    # further matches.
    #
    return 0

  else
    #
    # We are at the beginning of the processed list. We do not have any more
    # matches.
    #
    return 1
  fi
}

_history-substring-search-found() {
  #
  # A match is available. The index of the match is held in
  # $_history_substring_search_match_index
  #
  # 1. Keep BUFFER equal to the real prefix typed/accepted by the user.
  #
  # 2. Render only the unaccepted suffix through POSTDISPLAY.
  #
  _history-substring-search-set-suggestion "$history[$_history_substring_search_matches[$_history_substring_search_match_index]]"
}

_history-substring-search-not-found() {
  #
  # No more matches are available.
  #
  # 1. Keep BUFFER equal to $_history_substring_search_query so the user can
  #    revise it and search again.
  #
  # 2. Clear the suggestion preview.
  #
  BUFFER=$_history_substring_search_query
  _history_substring_search_suggestion=
  POSTDISPLAY=
}

_history-substring-search-up-search() {
  #
  # Select history entry during history-substring-down-search:
  #
  # The following variables have been initialized in
  # _history-substring-search-up/down-search():
  #
  # $_history_substring_search_matches is the current list of matches that
  # need to be displayed to the user.
  # $_history_substring_search_match_index is the index of the current match
  # that is being displayed to the user.
  #
  # The range of values that $_history_substring_search_match_index can take
  # is: [0, $#_history_substring_search_matches + 1].  A value of 0
  # indicates that we are beyond the beginning of
  # $_history_substring_search_matches. A value of
  # $#_history_substring_search_matches + 1 indicates that we are beyond
  # the end of $_history_substring_search_matches and that we have also
  # processed all entries in _history_substring_search_raw_matches.
  #
  # If $_history_substring_search_match_index equals
  # $#_history_substring_search_matches and
  # $_history_substring_search_raw_match_index is not greater than
  # $#_history_substring_search_raw_matches, then we need to further process
  # $_history_substring_search_raw_matches to see if there are any more
  # entries that need to be displayed to the user.
  #
  # In _history-substring-search-up-search() the initial value of
  # $_history_substring_search_match_index is 0. This value is set in
  # _history-substring-search-begin(). _history-substring-search-up-search()
  # will initially increment it to 1.
  #

  if [[ $_history_substring_search_match_index -gt $#_history_substring_search_matches ]]; then
    #
    # We are beyond the end of $_history_substring_search_matches. This
    # can only happen if we have also exhausted the unprocessed matches in
    # _history_substring_search_raw_matches.
    #
    # 1. Update display to indicate search not found.
    #
    _history-substring-search-not-found
    return
  fi

  if _history-substring-search-has-next; then
    #
    # We do have older matches.
    #
    # 1. Move index to point to the next match.
    # 2. Update display to indicate search found.
    #
    _history_substring_search_match_index+=1
    _history-substring-search-found

  else
    #
    # We do not have older matches.
    #
    # 1. Move the index beyond the end of
    #    _history_substring_search_matches.
    # 2. Update display to indicate search not found.
    #
    _history_substring_search_match_index+=1
    _history-substring-search-not-found
  fi

  #
  # When HIST_FIND_NO_DUPS is set, meaning that only unique command lines from
  # history should be matched, make sure the new and old results are different.
  #
  # However, if the HIST_IGNORE_ALL_DUPS shell option, or
  # HISTORY_SUBSTRING_SEARCH_ENSURE_UNIQUE is set, then we already have a
  # unique history, so in this case we do not need to do anything.
  #
  if [[ -o HIST_IGNORE_ALL_DUPS || -n $HISTORY_SUBSTRING_SEARCH_ENSURE_UNIQUE ]]; then
    return
  fi

  if [[ -o HIST_FIND_NO_DUPS && $_history_substring_search_suggestion == "$_history_substring_search_result" ]]; then
    #
    # Repeat the current search so that a different (unique) match is found.
    #
    _history-substring-search-up-search
  fi
}

_history-substring-search-down-search() {
  #
  # Select history entry during history-substring-down-search:
  #
  # The following variables have been initialized in
  # _history-substring-search-up/down-search():
  #
  # $_history_substring_search_matches is the current list of matches that
  # need to be displayed to the user.
  # $_history_substring_search_match_index is the index of the current match
  # that is being displayed to the user.
  #
  # The range of values that $_history_substring_search_match_index can take
  # is: [0, $#_history_substring_search_matches + 1].  A value of 0
  # indicates that we are beyond the beginning of
  # $_history_substring_search_matches. A value of
  # $#_history_substring_search_matches + 1 indicates that we are beyond
  # the end of $_history_substring_search_matches and that we have also
  # processed all entries in _history_substring_search_raw_matches.
  #
  # In _history-substring-search-down-search() the initial value of
  # $_history_substring_search_match_index is 1. This value is set in
  # _history-substring-search-begin(). _history-substring-search-down-search()
  # will initially decrement it to 0.
  #

  if [[ $_history_substring_search_match_index -lt 1 ]]; then
    #
    # We are beyond the beginning of $_history_substring_search_matches.
    #
    # 1. Update display to indicate search not found.
    #
    _history-substring-search-not-found
    return
  fi

  if _history-substring-search-has-prev; then
    #
    # We do have younger matches.
    #
    # 1. Move index to point to the previous match.
    # 2. Update display to indicate search found.
    #
    _history_substring_search_match_index+=-1
    _history-substring-search-found

  else
    #
    # We do not have younger matches.
    #
    # 1. Move the index beyond the beginning of
    #    _history_substring_search_matches.
    # 2. Update display to indicate search not found.
    #
    _history_substring_search_match_index+=-1
    _history-substring-search-not-found
  fi

  #
  # When HIST_FIND_NO_DUPS is set, meaning that only unique command lines from
  # history should be matched, make sure the new and old results are different.
  #
  # However, if the HIST_IGNORE_ALL_DUPS shell option, or
  # HISTORY_SUBSTRING_SEARCH_ENSURE_UNIQUE is set, then we already have a
  # unique history, so in this case we do not need to do anything.
  #
  if [[ -o HIST_IGNORE_ALL_DUPS || -n $HISTORY_SUBSTRING_SEARCH_ENSURE_UNIQUE ]]; then
    return
  fi

  if [[ -o HIST_FIND_NO_DUPS && $_history_substring_search_suggestion == "$_history_substring_search_result" ]]; then
    #
    # Repeat the current search so that a different (unique) match is found.
    #
    _history-substring-search-down-search
  fi
}

_history-substring-search-set-suggestion() {
  local suggestion=$1

  if [[ -n $suggestion && ${suggestion[1,${#BUFFER}]} == "$BUFFER" && ${#suggestion} -gt ${#BUFFER} ]]; then
    _history_substring_search_suggestion=$suggestion
    POSTDISPLAY=${suggestion[$(( ${#BUFFER} + 1 )),-1]}
  else
    _history_substring_search_suggestion=
    POSTDISPLAY=
  fi
}

# -*- mode: zsh; sh-indentation: 2; indent-tabs-mode: nil; sh-basic-offset: 2; -*-
# vim: ft=zsh sw=2 ts=2 et
