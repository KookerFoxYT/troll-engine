package playfields;

import flixel.graphics.FlxGraphic;
import JudgmentManager.Judgment;
import openfl.display.Shader;
import flixel.util.FlxColor;
import openfl.geom.Vector3D;
import flixel.math.FlxPoint;
import flixel.math.FlxMath;
import math.Vector3;
import flixel.system.FlxAssets.FlxShader;
import modchart.ModManager;
import flixel.group.FlxGroup.FlxTypedGroup;
import flixel.group.FlxSpriteGroup;
import lime.math.Vector2;
import lime.math.Vector4;
import openfl.Vector;
import flixel.tweens.FlxEase;
import flixel.util.FlxSort;
import flixel.tweens.FlxTween;
import lime.app.Event;
import flixel.math.FlxAngle;
import PlayState.Wife3;

using StringTools;

/*
The system is seperated into 3 classes:

- NoteField
    - This is the rendering component.
    - This can be created seperately from a PlayField to duplicate the notes multiple times, for example.
    - Needs to be linked to a PlayField though, so it can keep track of what notes exist, when notes get hit (to update receptors), etc.

- ProxyField
	- Clones a NoteField
	- This cannot have its own modifiers, etc applied. All this does is render whatever's in the NoteField
	- If you need to duplicate one PlayField a bunch, you should be using ProxyFields as they are far more optimized it only calls the mod manager for the initial notefield, and not any ProxyFields
	- One use case is if you wanna include an infinite NoteField effect (i.e the end of The Government Knows by FMS_Cat, or get f**ked from UKSRT8)

- PlayField
    - This is the gameplay component.
    - This keeps track of notes and updates them
    - This is typically per-player, and can control multiple characters, can be locked up, etc.
    - You can also swap which PlayField a player is actually controlling n all that
*/

/*
	If you use this code, please credit me (Nebula) and 4mbr0s3 2
	Or ATLEAST credit 4mbr0s3 2 since he did the cool stuff of this system (hold note manipulation)

	Note that if you want to use this in other mods, you'll have to do some pretty drastic changes to a bunch of classes (PlayState, Note, Conductor, etc)
	If you can make it work in other engines then epic but its best to just use this engine tbh
 */

typedef NoteCallback = (Note, PlayField) -> Void;
class PlayField extends FlxTypedGroup<FlxBasic>
{
	override function set_camera(to){
		for (strumLine in strumNotes)
			strumLine.camera = to;
		
		noteField.camera = to;

		return super.set_camera(to);
	}

	override function set_cameras(to){
		for (strumLine in strumNotes)
			strumLine.cameras = to;
		
		noteField.cameras = to;

		return super.set_cameras(to);
	}

	public var judgeManager(get, default):JudgmentManager; // for deriving judgements for input reasons
	function get_judgeManager()
		return judgeManager == null ? PlayState.instance.judgeManager : judgeManager;
	public var spawnedNotes:Array<Note> = []; // spawned notes
	public var spawnedByData:Array<Array<Note>> = [[], [], [], []]; // spawned notes by data. Used for input
	public var noteQueue:Array<Array<Note>> = [[], [], [], []]; // unspawned notes
	public var strumNotes:Array<StrumNote> = []; // receptors
	public var characters:Array<Character> = []; // characters that sing when field is hit
	public var noteField:NoteField; // renderer
	public var modNumber:Int = 0; // used for the mod manager. can be set to a different number to give it a different set of modifiers. can be set to 0 to sync the modifiers w/ bf's, and 1 to sync w/ the opponent's
	public var modManager:ModManager; // the mod manager. will be set automatically by playstate so dw bout this
	public var isPlayer:Bool = false; // if this playfield takes input from the player
	public var inControl:Bool = true; // if this playfield will take input at all
	public var keyCount(default, set):Int = 4; // How many lanes are in this field
	public var autoPlayed(default, set):Bool = false; // if this playfield should be played automatically (botplay, opponent, etc)

	function set_keyCount(cnt:Int){
		if (cnt < 0)
			cnt=0;
		if (spawnedByData.length < cnt){
			for (_ in (spawnedByData.length)...cnt)
				spawnedByData.push([]);
		}else if(spawnedByData.length > cnt){
			for (_ in cnt...spawnedByData.length)
				spawnedByData.pop();
		}

		if (noteQueue.length < cnt)
		{
			for (_ in (noteQueue.length)...cnt)
				noteQueue.push([]);
		}
		else if (noteQueue.length > cnt)
		{
			for (_ in cnt...noteQueue.length)
				noteQueue.pop();
		}
		if (keysPressed.length < cnt)
		{
			for (_ in (keysPressed.length)...cnt)
				keysPressed.push(false);
		}

		return keyCount = cnt;
	}

	function set_autoPlayed(aP:Bool){
		for (idx in 0...keysPressed.length)
			keysPressed[idx] = false;
		
		for(obj in strumNotes){
			obj.playAnim("static");
			obj.resetAnim = 0;
		}
		return autoPlayed = aP;
	}
	public var noteHitCallback:NoteCallback; // function that gets called when the note is hit. goodNoteHit and opponentNoteHit in playstate for eg
	public var grpNoteSplashes:FlxTypedGroup<NoteSplash>; // notesplashes
	public var strumAttachments:FlxTypedGroup<NoteObject>; // things that get "attached" to the receptors. custom splashes, etc.

	public var noteMissed:Event<NoteCallback> = new Event<NoteCallback>(); // event that gets called every time you miss a note. multiple functions can be bound here
	public var noteRemoved:Event<NoteCallback> = new Event<NoteCallback>(); // event that gets called every time a note is removed. multiple functions can be bound here
	public var noteSpawned:Event<NoteCallback> = new Event<NoteCallback>(); // event that gets called every time a note is spawned. multiple functions can be bound here

	public var keysPressed:Array<Bool> = [false,false,false,false]; // what keys are pressed rn

	public function new(modMgr:ModManager){
		super();
		this.modManager = modMgr;

		grpNoteSplashes = new FlxTypedGroup<NoteSplash>();
		add(grpNoteSplashes);

		strumAttachments = new FlxTypedGroup<NoteObject>();
		strumAttachments.visible = false;
		add(strumAttachments);

		var splash:NoteSplash = new NoteSplash(100, 100, 0);
		splash.handleRendering = false;
		grpNoteSplashes.add(splash);
		grpNoteSplashes.visible = false; // so they dont get drawn
		splash.alpha = 0.0;

		////
		noteField = new NoteField(this, modMgr);
		//add(noteField);

		// idk what haxeflixel does to regenerate the frames
		// SO! this will be how we do it
		// lil guy will sit here and regenerate the frames automatically
		// idk why this seems to work but it does	
		// TODO: figure out WHY this works
		var retard:StrumNote = new StrumNote(400, 400, 0);
		retard.playAnim("static");
		retard.alpha = 1;
		retard.visible = true;
		retard.color = FlxColor.BLACK; // just to make it a bit harder to see
		retard.alpha = 0.9; // just to make it a bit harder to see
		retard.scale.set(0.002, 0.002);
		retard.handleRendering = true;
		retard.updateHitbox();
		retard.x = 400;
		retard.y = 400;
		@:privateAccess
		retard.draw();
		add(retard);
	}

	// queues a note to be spawned
	public function queue(note:Note){
		if(noteQueue[note.noteData]==null)
			noteQueue[note.noteData] = [];
		noteQueue[note.noteData].push(note);

		noteQueue[note.noteData].sort((a, b) -> Std.int(a.strumTime - b.strumTime));
		
	}

	// unqueues a note
	public function unqueue(note:Note)
	{
		if (noteQueue[note.noteData] == null)
			noteQueue[note.noteData] = [];
		noteQueue[note.noteData].remove(note);
		noteQueue[note.noteData].sort((a, b) -> Std.int(a.strumTime - b.strumTime));
	}

	// destroys a note
	public function removeNote(daNote:Note){
		daNote.active = false;
		daNote.visible = false;

		noteRemoved.dispatch(daNote, this);

		daNote.kill();
		spawnedNotes.remove(daNote);
		if (spawnedByData[daNote.noteData] != null)
			spawnedByData[daNote.noteData].remove(daNote);

		if (noteQueue[daNote.noteData] != null)
			noteQueue[daNote.noteData].remove(daNote);

		if (daNote.unhitTail.length > 0)
			while (daNote.unhitTail.length > 0)
				removeNote(daNote.unhitTail.shift());
		

		if (daNote.parent != null && daNote.parent.tail.contains(daNote))
			daNote.parent.tail.remove(daNote);

 		if (daNote.parent != null && daNote.parent.unhitTail.contains(daNote))
			daNote.parent.unhitTail.remove(daNote); 

		if (noteQueue[daNote.noteData] != null)
			noteQueue[daNote.noteData].sort((a, b) -> Std.int(a.strumTime - b.strumTime));
		remove(daNote);
		daNote.destroy();
	}

	// spawns a note
	public function spawnNote(note:Note){
		if(note.spawned)
			return;
		
		if (noteQueue[note.noteData]!=null){
			noteQueue[note.noteData].remove(note);
			noteQueue[note.noteData].sort((a, b) -> Std.int(a.strumTime - b.strumTime));
		}

		if (spawnedByData[note.noteData]!=null)
			spawnedByData[note.noteData].push(note);
		else
			return;
		
		noteSpawned.dispatch(note, this);
		spawnedNotes.push(note);
		note.handleRendering = false;
		note.spawned = true;

		insert(0, note);
	}

	// gets all notes in the playfield, spawned or otherwise.

	public function getAllNotes(?dir:Int){
		var arr:Array<Note> = [];
		if(dir==null){
			for(queue in noteQueue){
				for(note in queue)
					arr.push(note);
				
			}
		}else{
			for (note in noteQueue[dir])
				arr.push(note);
		}
		for(note in spawnedNotes)
			arr.push(note);
		return arr;
	}
	
	// returns true if the playfield has the note, false otherwise.
	public function hasNote(note:Note)
		return spawnedNotes.contains(note) || noteQueue[note.noteData]!=null && noteQueue[note.noteData].contains(note);
	
	// sends an input to the playfield
	public function input(data:Int){
		if(data > keyCount || data < 0)return null;
		
		var noteList = getNotesWithEnd(data, Conductor.songPosition + ClientPrefs.hitWindow, (note:Note) -> !note.isSustainNote);
		#if PE_MOD_COMPATIBILITY
		noteList.sort((a, b) -> Std.int((a.strumTime + (a.lowPriority ? 10000 : 0)) - (b.strumTime + (b.lowPriority ? 10000 : 0)))); // so lowPriority actually works (even though i hate it lol!)
		#else
		noteList.sort((a, b) -> Std.int(a.strumTime - b.strumTime));
		#end
		while (noteList.length > 0)
		{
			var note:Note = noteList.shift();
			if(note.requiresTap){
				var judge:Judgment = judgeManager.judgeNote(note);
				if (judge != UNJUDGED){
					note.hitResult.judgment = judge;
					note.hitResult.hitDiff = note.strumTime - Conductor.songPosition;
					noteHitCallback(note, this);
					return note;
				}
			}
		}
		return null;
	}

	// generates the receptors
	public function generateStrums(){
		for(i in 0...keyCount){
			var babyArrow:StrumNote = new StrumNote(0, 0, i);
			babyArrow.downScroll = ClientPrefs.downScroll;
			babyArrow.alpha = 0;
			insert(0, babyArrow);
			babyArrow.handleRendering = false; // NoteField handles rendering
			babyArrow.cameras = cameras;
			strumNotes.push(babyArrow);
			babyArrow.postAddedToGroup();
		}
	}

	// does the introduction thing for the receptors. story mode usually sets skip to true. OYT uses this when mario comes in
	public function fadeIn(skip:Bool = false)
	{
		for (data in 0...strumNotes.length)
		{
			var babyArrow:StrumNote = strumNotes[data];
			if (skip)
				babyArrow.alpha = 1;
			else
			{
				babyArrow.alpha = 0;
				var daY = babyArrow.downScroll ? -10 : 10;
				babyArrow.offsetY -= daY;
				FlxTween.tween(babyArrow, {offsetY: babyArrow.offsetY + daY, alpha: 1}, 1, {ease: FlxEase.circOut, startDelay: 0.5 + (0.2 * data)});
			}
		}
	}

	// just sorts by z indexes, not used anymore tho
	function sortByOrderNote(Obj1:Note, Obj2:Note):Int
	{
		return FlxSort.byValues(FlxSort.ASCENDING, Obj1.zIndex, Obj2.zIndex);
	}

	// spawns a notesplash w/ specified skin. optional note to derive the skin and colours from.

	public function spawnSplash(data:Int, splashSkin:String, ?note:Note){
		var skin:String = splashSkin;
		var hue:Float = ClientPrefs.arrowHSV[data % 4][0] / 360;
		var sat:Float = ClientPrefs.arrowHSV[data % 4][1] / 100;
		var brt:Float = ClientPrefs.arrowHSV[data % 4][2] / 100;

		if (note != null)
		{
			skin = note.noteSplashTexture;
			hue = note.noteSplashHue;
			sat = note.noteSplashSat;
			brt = note.noteSplashBrt;
		}

		var splash:NoteSplash = grpNoteSplashes.recycle(NoteSplash);
		splash.setupNoteSplash(0, 0, data, skin, hue, sat, brt);
		splash.handleRendering = false;
		grpNoteSplashes.add(splash);
		return splash;
	}

	// spawns notes, deals w/ hold inputs, etc.
	override public function update(elapsed:Float){
		noteField.modNumber = modNumber;
		noteField.cameras = cameras;

		for(char in characters)
			char.controlled = isPlayer;
		
		var curDecStep:Float = 0;

		if ((FlxG.state is MusicBeatState))
		{
			var state:MusicBeatState = cast FlxG.state;
			@:privateAccess
			curDecStep = state.curDecStep;
		}
		else
		{
			var lastChange = Conductor.getBPMFromSeconds(Conductor.songPosition);
			var shit = ((Conductor.songPosition - ClientPrefs.noteOffset) - lastChange.songTime) / lastChange.stepCrochet;
			curDecStep = lastChange.stepTime + shit;
		}
		var curDecBeat = curDecStep / 4;

		for (data => column in noteQueue)
		{
			if (column[0] != null)
			{
				var dataSpawnTime = modManager.get("noteSpawnTime" + data); 
				var noteSpawnTime = (dataSpawnTime != null && dataSpawnTime.getValue(modNumber)>0)?dataSpawnTime:modManager.get("noteSpawnTime");
				var time:Float = noteSpawnTime == null ? 3000 : noteSpawnTime.getValue(modNumber); // no longer averages the spawn times
				while (column.length > 0 && column[0].strumTime - Conductor.songPosition < time)
					spawnNote(column[0]);
			}
		}

		super.update(elapsed);

		for(obj in strumNotes)
			modManager.updateObject(curDecBeat, obj, modNumber);

		//spawnedNotes.sort(sortByOrderNote);

		var garbage:Array<Note> = [];
		for (daNote in spawnedNotes)
		{
			if(!daNote.alive){
				spawnedNotes.remove(daNote);
				continue;
			}
			modManager.updateObject(curDecBeat, daNote, modNumber);

			// check for hold inputs
			if(!daNote.isSustainNote){
				if(daNote.noteData > keyCount-1){
					garbage.push(daNote);
					continue;
				}
				if(daNote.holdingTime < daNote.sustainLength && inControl && !daNote.blockHit){
					if(!daNote.tooLate && daNote.wasGoodHit){
						var isHeld = autoPlayed || keysPressed[daNote.noteData];
						//if(daNote.isRoll)isHeld = false; // roll logic is done on press
						// TODO: write that logic tho
						var receptor = strumNotes[daNote.noteData];
						
						// should i do this??? idfk lol
						if(isHeld && receptor.animation.curAnim.name!="confirm")
							receptor.playAnim("confirm", true);

						daNote.holdingTime = Conductor.songPosition - daNote.strumTime;
						var regrabTime = (daNote.isRoll?0.5:0.25) * judgeManager.judgeTimescale;
						if(isHeld)
							daNote.tripTimer = 1;
						else
							daNote.tripTimer -= elapsed / regrabTime; // NOTDO: regrab time multiplier in options
						// RE: nvm its done by the judge diff instead

						if(daNote.tripTimer <= 0){
							daNote.tripTimer = 0;
							daNote.tooLate=true;
							daNote.wasGoodHit=false;
							for(tail in daNote.unhitTail){
								tail.tooLate = true;
								tail.blockHit = true;
								tail.ignoreNote = true;
							}
						}else{
							for (tail in daNote.unhitTail)
							{
								if ((tail.strumTime - 25) <= Conductor.songPosition && !tail.wasGoodHit && !tail.tooLate){
									noteHitCallback(tail, this);
								}
							}

							if (daNote.holdingTime >= daNote.sustainLength)
							{
								daNote.holdingTime = daNote.sustainLength;
								
								if (!isHeld)
									receptor.playAnim("static", true);
							}

						}
					}
				}
			}
			// check for note deletion
			if (daNote.garbage)
			{
				garbage.push(daNote);
				continue;
			}
			else
			{

				if (daNote.tooLate && daNote.active && !daNote.causedMiss && !daNote.isSustainNote)
				{
					daNote.causedMiss = true;
					if (!daNote.ignoreNote && (daNote.tooLate || !daNote.wasGoodHit))
						noteMissed.dispatch(daNote, this);
				} 

				if((
					(daNote.holdingTime>=daNote.sustainLength || daNote.unhitTail.length==0 ) && daNote.sustainLength>0 ||
					daNote.isSustainNote && daNote.strumTime - Conductor.songPosition < -350 ||
					!daNote.isSustainNote && (daNote.sustainLength==0 || daNote.tooLate) && daNote.strumTime - Conductor.songPosition < -(200 + judgeManager.getWindow(TIER1))) && (daNote.tooLate || daNote.wasGoodHit))
				{
					garbage.push(daNote);
				}
				
			}
		}

		for(note in garbage){
			removeNote(note);
		}

		if (inControl && autoPlayed)
		{
			for(i in 0...keyCount){
				for (daNote in getNotes(i, (note:Note) -> !note.ignoreNote && !note.hitCausesMiss)){
					if (!daNote.isSustainNote){
						var hitDiff = Conductor.songPosition - daNote.strumTime;
						if (isPlayer && (hitDiff + ClientPrefs.ratingOffset) >= (-5 * (Wife3.timeScale > 1?1:Wife3.timeScale)) || hitDiff >= 0){
							daNote.hitResult.judgment = judgeManager.useEpics ? TIER5 : TIER4;
							daNote.hitResult.hitDiff = (hitDiff > -5) ? -5 : hitDiff; 
							if (noteHitCallback!=null)noteHitCallback(daNote, this);
						}
					}
				}
			}
		}else{
			for(data in 0...keyCount){
				if (keysPressed[data]){
					var noteList = getNotesWithEnd(data, Conductor.songPosition + ClientPrefs.hitWindow, (note:Note) -> !note.isSustainNote);
					#if PE_MOD_COMPATIBILITY
					noteList.sort((a, b) -> Std.int((a.strumTime + (a.lowPriority ? 10000 : 0)) - (b.strumTime + (b.lowPriority ? 10000 : 0)))); // so lowPriority actually works (even though i hate it lol!)
					#else
					noteList.sort((a, b) -> Std.int(a.strumTime - b.strumTime));
					#end
					while (noteList.length > 0)
					{
						var note:Note = noteList.shift();
						if(!note.requiresTap){
							var judge:Judgment = judgeManager.judgeNote(note);
							if (judge != UNJUDGED)
							{
								note.hitResult.judgment = judge;
								note.hitResult.hitDiff = note.strumTime - Conductor.songPosition;
								noteHitCallback(note, this);
							}
						}
					}
				}
			}
		}
	}
	

	// gets all living notes w/ optional filter

	public function getNotes(dir:Int, ?filter:Note->Bool):Array<Note>
	{
		if (spawnedByData[dir]==null)
			return [];

		var collected:Array<Note> = [];
		for (note in spawnedByData[dir])
		{
			if (note.alive && note.noteData == dir && !note.wasGoodHit && !note.tooLate)
			{
				if (filter == null || filter(note))
					collected.push(note);
			}
		}
		return collected;
	}

	// gets all living notes before a certain time w/ optional filter
	public function getNotesWithEnd(dir:Int, end:Float, ?filter:Note->Bool):Array<Note>
	{
		if (spawnedByData[dir] == null)
			return [];
		var collected:Array<Note> = [];
		for (note in spawnedByData[dir])
		{
			if (note.strumTime>end)break;
			if (note.alive && note.noteData == dir && !note.wasGoodHit && !note.tooLate)
			{
				if (filter == null || filter(note))
					collected.push(note);
			}
		}
		return collected;
	}

	function sortByShit(Obj1:Note, Obj2:Note):Int
	{
		return FlxSort.byValues(FlxSort.ASCENDING, Obj1.strumTime, Obj2.strumTime);
	}

	// go through every queued note and call a func on it
	public function forEachQueuedNote(callback:Note->Void)
	{
		for(column in noteQueue){
			var i:Int = 0;
			var note:Note = null;

			while (i < column.length)
			{
				note = column[i++];

				if (note != null && note.exists && note.alive)
					callback(note);
			}
		}
	}

	// kills all notes which are stacked
	public function clearStackedNotes(){
		var goobaeg:Array<Note> = [];
		for (column in noteQueue)
		{
			if (column.length >= 2)
			{
				for (nIdx in 1...column.length)
				{
					var last = column[nIdx - 1];
					var current = column[nIdx];
					if (last == null || current == null)
						continue;
					if (last.isSustainNote || current.isSustainNote)
						continue; // holds only get fukt if their parents get fukt
					if (!last.alive || !current.alive)
						continue; // just incase
					if (Math.abs(last.strumTime - current.strumTime) <= Conductor.stepCrochet / (192 / 16))
					{
						if (last.sustainLength < current.sustainLength) // keep the longer hold
							removeNote(last);
						else
						{
							current.kill();
							goobaeg.push(current); // mark to delete after, cant delete here because otherwise it'd fuck w/ stuff
						}
					}
				}
			}
		}
		for (note in goobaeg)
			removeNote(note);
	}

	// as is in the name, removes all dead notes
	public function clearDeadNotes(){
		var dead:Array<Note> = [];
		for(note in spawnedNotes){
			if(!note.alive)
				dead.push(note);
			
		}
		for(column in noteQueue){
			for(note in column){
				if(!note.alive)
					dead.push(note);
			}
			
		}

		for(note in dead)
			removeNote(note);
	}


	override function destroy(){
		noteSpawned.removeAll();
		noteSpawned.cancel();
		noteMissed.removeAll();
		noteMissed.cancel();
		noteRemoved.removeAll();
		noteRemoved.cancel();

		return super.destroy();
	}
}