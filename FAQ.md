# Frequently Asked Questiond and Troubleshooting

This page tries to answer some common concerns, so if you have questions or problems then try to see if any of this helps.

## Installation

### 1. How do I install this mod? Do I have to enable it in FFB Tweaks?

Normally you can just install it by dragging the zip file into Content Manager, then from there the UI app will take care of the rest. Technically there is an FFB post-processing script component that needs to be enabled in the CSP FFB Tweaks settings, but the app will automatically do this for you. If somehow the app fails at doing this then read the next section.

### 2. Can't enable the FFB post-processing script from the app.

Normally the first time you install this mod there is an "enable" button in the app that sorts out the CSP settings required for the FFB post-processing script to work. If clicking this doesn't work, you can try restarting AC and Content Manager, re-installing the mod, or checking the post-processing script settings by hand. 

You can manually check the required settings by going to Content Manager ➔ Settings ➔ Custom Shaders Patch ➔ FFB Tweaks. Here you have to do the following:

 - Enable the ***Active*** checkbox under ***Basic*** (should be at the top)
 - Enable the ***Active*** checkbox under ***Additional post-processing script***
 - In the ***Script*** dropdown select ***Adam's FFB Toolbox***

If you don't have that option from the last step then try restarting Content Manager and checking again. If it still doesn't show up then try installing the mod by hand. This means extracting the zip file and copying the ***apps*** and ***extensions*** folders into your main ***assettocorsa*** folder (instead of just dropping the zip into Content Manager). If this doesn't help either, then try deleting the mod completely (see the next section) before installing it manually again.

### 3. I want to uninstall this mod.

First, you should be aware that unchecking the ***Enable FFB processing*** checkbox in the app will ensure that your FFB is not changed in any way, so it's very easy to disable it completely if you don't like what it's doing.

But if you really want to delete the mod completely, then you have to delete these two folders:

`assettocorsa\extension\lua\ffb-postprocess\Adam's FFB Toolbox`

`assettocorsa\apps\lua\Adam's FFB Toolbox Config`

## Usage / Features

### 1. My FFB now feels too strong or too light.

This is probably because you've enabled the ***Auto-adjust gain*** option. This option will automatically set the per-car FFB gain in an attempt to make each car have a similar level of FFB.

When you use this option you have to make sure that no other app or script is trying to auto-adjust your gain at the same time. Multiple apps trying to adjust FFB gain can have chaotic results.

The version built into this mod is done in a way that tries to match the actual FFB level of the car to your global FFB gain setting. For example if your global FFB gain is set to 50% then this setting will set the per-car FFB gain to a level that should make the car produce around 50% FFB output when turning into a corner. You can verify this by enabling the FFB graph in the app (on the ***Graph*** tab).

Hopefully this explains why your gain was set the way it was. The idea is that with this setting enabled you shouldn't have to think about the per-car FFB gain anymore, but only your global FFB level.

However, the gain calculations can sometimes be a bit off depending on the car. With Kunos cars this shouldn't get too bad, maybe ±20% off at worst. These smaller errors can be easily fixed with the ***Auto-gain offset*** setting on the ***Car-specific*** tab, but most cars don't even need this step.

But especially with certain mod cars the error can be bigger. I did my best to test as many mod cars as I can, and the auto-gain does work well with most of them (similar to Kunos cars), but there are always a certain few mod cars that were made in unconventional ways that can throw off the auto-gain.

**TL;DR** If you're driving a mod car and the FFB gain seems to be way off, just disable the ***Auto-adjust gain*** on the ***Car-specific*** tab and tune the car's FFB gain yourself. This should be rare, but it can happen.

### 2. Can I use this with Alternative FFB: Extended (or any other post-processing script)?

No. This mod also comes with its own FFB post processing-script that's responsible for actually applying the effects to your FFB, and CSP can only run one post-processing script at a time. There's not much I can do about it, so you have to pick just one script to use (which this mod also counts as).

### 3. How do I report an issue or ask further questions?

Post in the [Overtake thread](https://www.overtake.gg/threads/adams-ffb-toolbox.296251/) of the mod, that's where I can respond to things the easiest.