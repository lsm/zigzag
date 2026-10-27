//! Safe Rust control. Entire module uses safe Rust (no unsafe blocks or crates).
const MAX_LEN: usize = 64;

#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    TooLong,
}

fn sum(bytes: &[u8]) -> u64 {
    bytes.iter().map(|&n| u64::from(n)).sum()
}

pub fn copy_and_sum(input: &[u8]) -> Result<u64, Error> {
    if input.len() > MAX_LEN {
        return Err(Error::TooLong);
    }
    let owned = input.to_vec();
    Ok(sum(&owned))
}

pub fn parallel_sum(input: &[u8]) -> u64 {
    let (left, right) = input.split_at(input.len() / 2);
    std::thread::scope(|scope| {
        let a = scope.spawn(|| sum(left));
        let b = scope.spawn(|| sum(right));
        a.join().unwrap() + b.join().unwrap()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn copy_and_boundaries() {
        assert_eq!(copy_and_sum(&[]), Ok(0));
        assert_eq!(copy_and_sum(&[1, 2, 3, 4]), Ok(10));
        assert_eq!(copy_and_sum(&[2; 64]), Ok(128));
        assert_eq!(copy_and_sum(&[1; 65]), Err(Error::TooLong));
    }

    #[test]
    fn two_threads_with_immutable_split() {
        assert_eq!(parallel_sum(&[1, 2, 3, 4]), 10);
        assert_eq!(parallel_sum(&[]), 0);
    }
}
