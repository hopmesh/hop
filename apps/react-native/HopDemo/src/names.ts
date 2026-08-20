const adjectives = [
  'amber',
  'bold',
  'brave',
  'bright',
  'calm',
  'clever',
  'cosmic',
  'crisp',
  'daring',
  'eager',
  'gentle',
  'golden',
  'happy',
  'keen',
  'lively',
  'lucky',
  'mellow',
  'nimble',
  'noble',
  'quiet',
  'rapid',
  'ready',
  'silver',
  'steady',
  'sunny',
  'swift',
  'tidy',
  'vivid',
  'warm',
  'wild',
  'wise',
  'zesty',
] as const;

const animals = [
  'badger',
  'bear',
  'beaver',
  'bison',
  'bobcat',
  'crane',
  'dolphin',
  'falcon',
  'fox',
  'gecko',
  'heron',
  'ibex',
  'jaguar',
  'koala',
  'lemur',
  'lynx',
  'marten',
  'otter',
  'owl',
  'panda',
  'puma',
  'raven',
  'seal',
  'shark',
  'sparrow',
  'stoat',
  'tiger',
  'turtle',
  'whale',
  'wolf',
  'wren',
  'yak',
] as const;

export const PARTICIPANT_NAME_COMBINATIONS = adjectives.length * animals.length;

export function generateParticipantName(rng: () => number = Math.random): string {
  const sample = rng();
  if (!Number.isFinite(sample) || sample < 0 || sample >= 1) {
    throw new RangeError('participant name RNG must return a finite number from 0 up to, but not including, 1');
  }

  const choice = Math.floor(sample * PARTICIPANT_NAME_COMBINATIONS);
  const adjective = adjectives[Math.floor(choice / animals.length)];
  const animal = animals[choice % animals.length];
  return `${adjective}-${animal}`;
}
