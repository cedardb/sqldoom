-- Menu layout in Doom's own screen coordinates (m_menu.c):
-- main menu at x=97 y=64, episode/skill at x=48 y=63,
-- Load/Save slots at x=80 y=54, LINEHEIGHT 16 throughout.
TRUNCATE menu_items;
TRUNCATE menu_decor;

INSERT INTO menu_items (screen,idx,patch,x,y) VALUES
  ('main',0,'M_NGAME',97,64),
  ('main',1,'M_OPTION',97,80),
  ('main',2,'M_LOADG',97,96),
  ('main',3,'M_SAVEG',97,112),
  ('main',4,'M_RDTHIS',97,128),
  ('main',5,'M_QUITG',97,144),
  ('episode',0,'M_EPI1',48,63),
  ('episode',1,'M_EPI2',48,79),
  ('episode',2,'M_EPI3',48,95),
  ('episode',3,'M_EPI4',48,111),
  ('skill',0,'M_JKILL',48,63),
  ('skill',1,'M_ROUGH',48,79),
  ('skill',2,'M_HURT',48,95),
  ('skill',3,'M_ULTRA',48,111),
  ('skill',4,'M_NMARE',48,127),
  ('load',0,NULL,80,54),
  ('load',1,NULL,80,70),
  ('load',2,NULL,80,86),
  ('load',3,NULL,80,102),
  ('load',4,NULL,80,118),
  ('load',5,NULL,80,134),
  ('save',0,NULL,80,54),
  ('save',1,NULL,80,70),
  ('save',2,NULL,80,86),
  ('save',3,NULL,80,102),
  ('save',4,NULL,80,118),
  ('save',5,NULL,80,134);

INSERT INTO menu_decor (screen,seq,patch,x,y) VALUES
  ('title',0,'TITLEPIC',0,0),
  ('main',0,'M_DOOM',94,2),
  ('episode',0,'M_EPISOD',54,38),
  ('skill',0,'M_NEWG',96,14),
  ('skill',1,'M_SKILL',54,38),
  ('load',0,'M_LOADG',72,28),
  ('save',0,'M_SAVEG',72,28);

INSERT INTO screen_state (id,screen) VALUES (0,'title')
ON CONFLICT (id) DO NOTHING;
