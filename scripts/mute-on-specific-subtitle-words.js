/**
 * Script which observes subtitle changes for specified words (as defined in the words array)
 * and mutes mpv and hides subtitles (for the duration of that specific subtitle).
 * Unmutes and retores previous subtitle visibility when muted subtitle ends.
 */

//Define list of words to mute (and hide subtitles) - add your own words here.
var words = ['ass', 'bitch', 'fuck', 'shit'];
var subvis = "yes"; // init

/**
 * Checks subtitle text for specified words (as defined in the words array).
 * Uses boundary word regex check to minimise false positives.
 * @param {String} name 
 * @param {String} value 
 */
function on_subtitle(name, value) {
    if (!value) {
        mute(false);
        return;
    }

    // get subtitle visibility (for next restore)
    subvis = mp.get_property("sub-visibility");

    // check for bad word regex match on current subtitle text
    if (words.some(function (v) {
        if (!value) {
            return false;
        }
        // ignore case and use word boundary match on bad word
        return new RegExp("\\b"+ v + "\\b", 'i').test(value);
    })) {
        mute(true);
    } else {
        mute(false);
    }
}

/**
 * Mutes and hides subtitles (visibility) in mpv iff true.
 * @param {Boolean} option 
 */
function mute(option) {
    if (option) {
        mp.set_property("ao-mute", "yes");
        mp.set_property("sub-visibility", "no");
    } else {
        mp.set_property("ao-mute", "no");
        mp.set_property("sub-visibility", subvis);
    }
}

// set observer for all subtitle text changes
mp.observe_property("sub-text", "string", on_subtitle);