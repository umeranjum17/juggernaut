"""Which release a board ticket may name: only one the local trunk has cut, a branch in data/trunk-releases.tsv."""


def cut(data):
    """The release names the trunk has cut in this home: column 2 of each row (project, branch, tip, count, epoch, url)."""
    try:
        with open(data / 'trunk-releases.tsv') as table:
            return {cells[1] for cells in (line.split('\t') for line in table) if len(cells) > 1}
    except OSError:
        return set()


def name(value, cut_names):
    """The ticket's release when the trunk cut it, else none: a PR-era version or a timing word is no release."""
    return value if value in cut_names else ''
