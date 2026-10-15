// The lists the fake-data helpers pick from. They are part of format
// version 1: they ship inside the binary and never change within it, so
// that a seed gives the same words and names in every release.

///|
/// 256 lower-case English words, for `fake.word()` and `fake.words(n)`.
let words : Array[String] = [
  "able", "acid", "actor", "admit", "adult", "after", "again", "agent", "agree",
  "ahead", "alarm", "album", "alert", "alley", "allow", "alone", "amber", "anchor",
  "angle", "apple", "april", "arena", "argue", "arrow", "aside", "atlas", "audio",
  "autumn", "avenue", "badge", "baker", "basin", "beach", "beacon", "berry", "bicycle",
  "binder", "birch", "blade", "blank", "blanket", "bloom", "board", "bonus", "border",
  "bottle", "branch", "brave", "bread", "brick", "bridge", "bright", "bronze", "brush",
  "bucket", "budget", "bundle", "button", "cabin", "cable", "cactus", "camera", "canal",
  "candle", "canvas", "canyon", "carbon", "cargo", "carpet", "castle", "cedar", "chair",
  "chalk", "channel", "cherry", "chess", "circle", "citrus", "clay", "cliff", "clock",
  "cloud", "clover", "coast", "cobalt", "comet", "compass", "copper", "coral", "cotton",
  "crane", "crayon", "creek", "crown", "crystal", "cushion", "dawn", "delta", "desert",
  "diamond", "dinner", "dolphin", "dragon", "drawer", "dream", "drift", "eagle",
  "earth", "echo", "elbow", "ember", "engine", "fabric", "falcon", "feather", "fence",
  "fern", "field", "flame", "flint", "forest", "fossil", "fountain", "frame", "galaxy",
  "garden", "garlic", "ginger", "glacier", "globe", "granite", "grape", "gravel",
  "habit", "hammer", "harbor", "harp", "harvest", "hazel", "helmet", "honey", "horizon",
  "island", "ivory", "jacket", "jasmine", "jewel", "jungle", "kernel", "kettle",
  "ladder", "lagoon", "lantern", "lemon", "letter", "linen", "lizard", "lotus", "magnet",
  "mango", "maple", "marble", "meadow", "melody", "mirror", "mitten", "monsoon",
  "mosaic", "mountain", "napkin", "nectar", "needle", "nickel", "noodle", "nutmeg",
  "oasis", "ocean", "olive", "orange", "orbit", "orchard", "otter", "oyster", "paddle",
  "palace", "panda", "paper", "parrot", "pearl", "pebble", "pencil", "pepper", "piano",
  "pillow", "pine", "planet", "plaza", "pocket", "pollen", "pond", "puzzle", "quartz",
  "quiet", "rabbit", "radar", "rainbow", "raven", "reef", "ribbon", "river", "rocket",
  "saddle", "sailor", "salmon", "sandal", "satin", "scarf", "shadow", "shell", "signal",
  "silver", "socket", "spark", "spiral", "spring", "squash", "stable", "stone", "summit",
  "sunset", "swallow", "table", "temple", "thunder", "ticket", "timber", "tomato",
  "torch", "tower", "trail", "tulip", "tunnel", "turtle", "umbrella", "valley", "velvet",
  "violet", "voyage", "wagon", "walnut", "wander", "window", "winter", "wizard",
  "yellow", "zebra",
]

///|
/// 128 ASCII first names, for `fake.firstName()`, `fake.name()` and
/// `fake.email()`.
let first_names : Array[String] = [
  "Aaron", "Abigail", "Adam", "Adrian", "Aiden", "Alan", "Albert", "Alice", "Amara",
  "Amelia", "Ana", "Andrew", "Anna", "Arthur", "Aria", "Ava", "Benjamin", "Bianca",
  "Boris", "Caleb", "Camila", "Carlos", "Caroline", "Charles", "Chloe", "Clara",
  "Daniel", "David", "Diana", "Dmitri", "Elena", "Eli", "Elias", "Ella", "Emil",
  "Emily", "Emma", "Eric", "Ethan", "Eva", "Felix", "Fiona", "Florence", "Gabriel",
  "Grace", "Hana", "Hannah", "Harper", "Henry", "Hugo", "Ian", "Ingrid", "Isaac",
  "Isabel", "Ivan", "Jack", "Jacob", "James", "Jasmine", "Javier", "Julia", "Julian",
  "Kai", "Karen", "Kenji", "Laila", "Laura", "Leah", "Leo", "Liam", "Lily", "Lucas",
  "Lucy", "Luis", "Maya", "Marco", "Maria", "Martin", "Mason", "Mateo", "Mei", "Mia",
  "Michael", "Mila", "Nadia", "Naomi", "Nathan", "Nina", "Noah", "Nora", "Oliver",
  "Olivia", "Omar", "Oscar", "Paul", "Pedro", "Priya", "Rachel", "Rafael", "Ravi",
  "Rosa", "Ruby", "Ryan", "Samuel", "Sara", "Sebastian", "Sofia", "Sophie", "Stella",
  "Theo", "Thomas", "Tomas", "Uma", "Victor", "Victoria", "Vivian", "Walter", "William",
  "Xavier", "Yara", "Yuki", "Yusuf", "Zara", "Zoe", "Ahmed", "Beatrice", "Chen",
  "Dora",
]

///|
/// 128 ASCII last names, for `fake.lastName()`, `fake.name()` and
/// `fake.email()`.
let last_names : Array[String] = [
  "Abbott", "Adams", "Alvarez", "Anderson", "Bailey", "Baker", "Barnes", "Becker",
  "Bell", "Bennett", "Berg", "Brooks", "Brown", "Bryant", "Butler", "Campbell", "Carter",
  "Castro", "Chang", "Clark", "Cole", "Collins", "Cook", "Cooper", "Cruz", "Davies",
  "Diaz", "Dixon", "Duncan", "Edwards", "Ellis", "Evans", "Fischer", "Fisher", "Fleming",
  "Ford", "Foster", "Fraser", "Garcia", "Gibson", "Gomez", "Graham", "Grant", "Gray",
  "Green", "Hall", "Hansen", "Harris", "Hayes", "Henderson", "Hill", "Holmes", "Hughes",
  "Hunt", "Jensen", "Johnson", "Jones", "Kelly", "Kennedy", "Kim", "King", "Klein",
  "Kowalski", "Larsen", "Lee", "Lewis", "Lopez", "Martin", "Mason", "Meyer", "Miller",
  "Mitchell", "Moore", "Morales", "Morgan", "Murphy", "Nakamura", "Nelson", "Nguyen",
  "Novak", "Olsen", "Ortiz", "Owens", "Parker", "Patel", "Perez", "Perry", "Peters",
  "Phillips", "Porter", "Price", "Quinn", "Ramirez", "Reed", "Reyes", "Richter",
  "Rivera", "Roberts", "Rossi", "Russell", "Sanders", "Santos", "Schmidt", "Scott",
  "Shaw", "Silva", "Simmons", "Singh", "Stewart", "Sullivan", "Suzuki", "Tanaka",
  "Taylor", "Thomas", "Torres", "Turner", "Vargas", "Walker", "Wallace", "Ward",
  "Watson", "Weber", "White", "Wilson", "Wright", "Young", "Zhang", "Zimmerman",
]
